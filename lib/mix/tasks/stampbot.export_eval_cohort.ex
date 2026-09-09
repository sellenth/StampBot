defmodule Mix.Tasks.Stampbot.ExportEvalCohort do
  @moduledoc """
  Exports a private, stratified review cohort from actual failed or degraded submissions.

      mix stampbot.export_eval_cohort --output tmp/evals/cohort

  Starts only the repository and its dependencies, uses a read-only transaction,
  and never fetches media, runs models, or publishes comments. The output includes
  video identities, so keep it private. No credentials, user names, source text,
  generated text, or raw error bodies are selected or exported.
  """
  use Mix.Task
  import Ecto.Query
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.YouTube.URL

  @shortdoc "Export a private failed/degraded video cohort for human evaluation"
  @switches [
    output: :string,
    scan_limit: :integer,
    per_stratum: :integer,
    held_out_percent: :integer
  ]
  @split_seed "stampbot-video-holdout-v1"
  @failure_categories ~w(captions_unavailable captions_empty captions_fetch_failed
    caption_downloader_outdated caption_downloader_unavailable caption_runtime_outdated
    youtube_auth_failed youtube_rate_limited youtube_network_error video_unavailable
    transcript_empty gemini_error timestamp_extraction_failed no_timestamps
    missing_api_key video_id_not_found transcript_too_large work_budget_exceeded
    input_limit_exceeded unwatched incomplete_output)

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("Unknown cohort export arguments")
    output = opts[:output] || Mix.raise("Choose a private output directory with --output PATH")
    validate_options!(opts)
    Mix.Task.run("app.config")

    if Process.whereis(DragNStamp.Supervisor),
      do: Mix.raise("Run this Mix task by itself; application workers must remain stopped")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, repo} = Repo.start_link()

    try do
      limit = Keyword.get(opts, :scan_limit, 10_000)

      {:ok, rows} =
        Repo.transaction(
          fn ->
            Repo.query!("SET TRANSACTION READ ONLY")
            Repo.query!("SET LOCAL statement_timeout = '30s'")
            Repo.all(candidate_query(limit))
          end,
          timeout: 35_000
        )

      manifest = build_manifest(rows, opts)
      write_artifacts!(manifest, output)

      Mix.shell().info(
        "Exported #{length(manifest.videos)} video identities to #{Path.expand(output)}. " <>
          "No live evaluation was run; chapter quality and current source availability are unreviewed."
      )
    after
      Supervisor.stop(repo)
    end
  end

  @doc false
  def candidate_query(scan_limit) do
    from t in Timestamp,
      where:
        t.processing_status == :failed or
          (t.processing_status == :ready and
             (is_nil(t.content) or t.content == "" or
                is_nil(t.distilled_content) or t.distilled_content == "" or
                fragment(
                  "coalesce(? ->> 'distillation_failed', '') = 'true'",
                  t.processing_context
                ) or
                fragment(
                  "coalesce(? #>> '{caption_attempts,0,trigger}', '') = 'vlm_failure'",
                  t.processing_context
                ) or
                fragment("position('UNWATCHED' in upper(coalesce(?, ''))) > 0", t.content) or
                fragment(
                  "position('UNWATCHED' in upper(coalesce(?, ''))) > 0",
                  t.distilled_content
                ))),
      order_by: [desc: t.updated_at, desc: t.id],
      limit: ^scan_limit,
      select: %{
        id: t.id,
        url: t.url,
        video_id: t.video_id,
        duration_seconds: t.video_duration_seconds,
        processing_status: t.processing_status,
        updated_at: t.updated_at,
        has_primary: not is_nil(t.content) and t.content != "",
        has_distilled: not is_nil(t.distilled_content) and t.distilled_content != "",
        unwatched:
          fragment(
            "position('UNWATCHED' in upper(coalesce(?, '') || coalesce(?, ''))) > 0",
            t.content,
            t.distilled_content
          ),
        distillation_failed:
          fragment("coalesce(? ->> 'distillation_failed', '') = 'true'", t.processing_context),
        caption_failure: fragment("? #>> '{captions_summary,last_reason}'", t.processing_context),
        caption_trigger: fragment("? #>> '{caption_attempts,0,trigger}'", t.processing_context),
        caption_language:
          fragment("? #>> '{caption_attempts,0,caption_context,language}'", t.processing_context)
      }
  end

  @doc false
  def build_manifest(rows, opts \\ []) do
    validate_options!(opts)
    per_stratum = Keyword.get(opts, :per_stratum, 10)
    holdout = Keyword.get(opts, :held_out_percent, 20)

    normalized = Enum.flat_map(rows, &normalize_row(&1, holdout))

    # One source identity can never occur in both tuning and held-out sets.
    unique =
      normalized
      |> Enum.group_by(& &1.video_id)
      |> Enum.map(fn {_id, candidates} ->
        candidates
        |> Enum.sort_by(&{severity(&1.outcome), -&1.source_submission_id})
        |> hd()
        |> Map.put(:matching_submission_count, length(candidates))
      end)

    groups = Enum.group_by(unique, & &1.stratum)

    videos =
      groups
      |> Enum.flat_map(fn {_stratum, candidates} ->
        candidates |> Enum.sort_by(&digest("sample:" <> &1.video_id)) |> Enum.take(per_stratum)
      end)
      |> Enum.sort_by(&{&1.stratum, &1.cohort_id})

    %{
      version: 1,
      generated_at: DateTime.utc_now(),
      provenance:
        "Actual database submissions; historical outcomes, not current source availability",
      selection: %{
        scope:
          "failed or ready with missing distillation, failed distillation, video fallback, or UNWATCHED",
        order: "most recently updated matching submissions within scan_limit",
        scan_limit: Keyword.get(opts, :scan_limit, 10_000),
        matching_rows_read: length(rows),
        scan_limit_reached: length(rows) >= Keyword.get(opts, :scan_limit, 10_000),
        invalid_or_ineligible_rows_omitted: length(rows) - length(normalized),
        unique_video_candidates: length(unique),
        per_stratum: per_stratum,
        selected_videos: length(videos),
        stratification: [
          "historical_outcome",
          "failure_category",
          "duration_bucket",
          "recorded_caption_language"
        ]
      },
      split: %{
        seed: @split_seed,
        method: "SHA-256(seed:video_id), first unsigned 64 bits modulo 10000",
        held_out_percent: holdout,
        instruction:
          "Freeze the exported manifest before tuning; never move held-out videos into tuning"
      },
      coverage:
        groups
        |> Enum.map(fn {stratum, candidates} ->
          selected = Enum.filter(videos, &(&1.stratum == stratum))

          %{
            stratum: stratum,
            candidate_videos: length(candidates),
            selected_videos: length(selected),
            held_out_videos: Enum.count(selected, &(&1.split == "held_out"))
          }
        end)
        |> Enum.sort_by(& &1.stratum),
      limitations: [
        "Failure-focused sample cannot estimate overall production success rate",
        "Historical metadata may be stale; caption language is recorded metadata, not verified speech language",
        "Unknown failure categories are retained as unknown; raw errors are not exported",
        "Missing healthy controls, private/access-restricted provenance, and recent-upload coverage need review",
        "Small strata may contain no held-out cases; expand the frozen cohort rather than changing split assignments",
        "Historical model cost and latency are not inferred from retained results; live attempt-ledger metrics are required"
      ],
      semantic_quality: "UNREVIEWED",
      live_calls: 0,
      videos: videos
    }
  end

  defp normalize_row(row, holdout) do
    with {:ok, identity} <- identity(row),
         outcome when not is_nil(outcome) <- outcome(row) do
      language = recorded_language(row[:caption_language])
      bucket = duration_bucket(row[:duration_seconds])
      failure = failure_category(row[:caption_failure], outcome)

      [
        %{
          cohort_id: "video_" <> String.slice(digest(identity.video_id), 0, 16),
          video_id: identity.video_id,
          url: identity.url,
          source_submission_id: row.id,
          source_updated_at: row[:updated_at],
          duration_seconds: row[:duration_seconds],
          duration_bucket: bucket,
          caption_language: language,
          language_provenance:
            if(language == "unknown", do: "not_recorded", else: "caption_adapter_metadata"),
          outcome: outcome,
          failure_category: failure,
          stratum: Enum.join([outcome, failure, bucket, language], "/"),
          split: split(identity.video_id, holdout),
          source_availability: "unreviewed",
          chapter_quality: "unreviewed"
        }
      ]
    else
      _ -> []
    end
  end

  defp identity(%{video_id: id}) when is_binary(id) and byte_size(id) == 11,
    do: URL.parse("https://www.youtube.com/watch?v=#{id}")

  defp identity(row), do: URL.parse(row[:url])

  defp outcome(%{processing_status: status}) when status in [:failed, "failed"], do: "failed"
  defp outcome(%{unwatched: true}), do: "unusable_unwatched"
  defp outcome(%{has_primary: false}), do: "missing_primary"
  defp outcome(%{distillation_failed: true}), do: "distillation_failed"
  defp outcome(%{has_distilled: false}), do: "primary_only"
  defp outcome(%{caption_trigger: "vlm_failure"}), do: "video_fallback_recovered"
  defp outcome(_), do: nil

  defp failure_category(_value, "unusable_unwatched"), do: "unwatched"
  defp failure_category(_value, "distillation_failed"), do: "distillation_failed"
  defp failure_category(value, "failed") when value in @failure_categories, do: value
  defp failure_category(_value, _outcome), do: "unknown"

  defp duration_bucket(seconds) when not is_integer(seconds) or seconds <= 0, do: "unknown"
  defp duration_bucket(seconds) when seconds <= 1_200, do: "short_0_to_20m"
  defp duration_bucket(seconds) when seconds <= 3_600, do: "medium_20_to_60m"
  defp duration_bucket(_seconds), do: "long_over_60m"

  defp recorded_language(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z]{2,3}(?:[-_][a-zA-Z0-9]{2,8}){0,2}$/, value),
      do: String.downcase(value),
      else: "unknown"
  end

  defp recorded_language(_value), do: "unknown"
  defp severity("failed"), do: 0
  defp severity("unusable_unwatched"), do: 1
  defp severity(_outcome), do: 2

  defp split(id, holdout) do
    <<value::unsigned-big-integer-size(64), _::binary>> =
      :crypto.hash(:sha256, @split_seed <> ":" <> id)

    if rem(value, 10_000) < holdout * 100, do: "held_out", else: "tuning"
  end

  defp digest(value),
    do: :crypto.hash(:sha256, @split_seed <> ":" <> value) |> Base.encode16(case: :lower)

  defp validate_options!(opts) do
    for {name, default, minimum, maximum} <- [
          {:scan_limit, 10_000, 1, 100_000},
          {:per_stratum, 10, 1, 1_000},
          {:held_out_percent, 20, 1, 99}
        ] do
      value = Keyword.get(opts, name, default)

      unless is_integer(value) and value >= minimum and value <= maximum,
        do:
          Mix.raise(
            "--#{String.replace(to_string(name), "_", "-")} must be #{minimum}..#{maximum}"
          )
    end
  end

  @doc false
  def write_artifacts!(manifest, directory) do
    File.mkdir_p!(Path.dirname(directory))
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    for {name, content} <- [
          {"manifest.json", Jason.encode!(manifest, pretty: true) <> "\n"},
          {"review.csv", review_csv(manifest.videos)}
        ] do
      path = Path.join(directory, name)
      # Refuse accidental replacement of a frozen cohort or human review sheet.
      {:ok, file} = File.open(path, [:write, :exclusive, :utf8])

      try do
        IO.write(file, content)
      after
        File.close(file)
      end

      File.chmod!(path, 0o600)
    end

    :ok
  end

  @doc false
  def review_csv(videos) do
    headers = ~w(cohort_id split url outcome duration_bucket caption_language source_availability
      pipeline_revision model_configuration run_artifact acquisition_outcome completion_outcome
      usable_chapters factual_support_0_to_2 boundary_accuracy_0_to_2 coverage_0_to_2
      title_usefulness_0_to_2 safety_pass reviewer evidence_timecodes notes)

    rows =
      Enum.map(videos, fn video ->
        fields = Map.new(video, fn {key, value} -> {to_string(key), value} end)
        Enum.map(headers, fn header -> Map.get(fields, header, "") end)
      end)

    # Headers also define the only fields allowed into the worksheet.
    [headers | rows]
    |> Enum.map_join("\r\n", &Enum.map_join(&1, ",", fn value -> csv_cell(value) end))
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(value) do
    text = to_string(value || "")
    text = if Regex.match?(~r/^[=+\-@\t\r]/, text), do: "'" <> text, else: text
    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
  end
end
