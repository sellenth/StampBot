# Run with MIX_ENV=test mix run --no-start evals/production_baseline.exs
Code.require_file("support/fixture_io.exs", __DIR__)

defmodule StampBot.Evals.ProductionBaseline do
  @moduledoc false
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Submissions.Processor
  alias DragNStamp.YouTube.URL
  alias StampBot.Evals.FixtureIO

  @root __DIR__

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, case: :string, list: :boolean, live: :boolean, video: :string]
      )

    if rest != [] or invalid != [],
      do: raise("Unknown eval arguments: #{inspect(rest ++ invalid)}")

    manifest = read_json("production_baseline.json")

    cond do
      opts[:list] -> Enum.each(manifest["cases"], &IO.puts(&1["id"]))
      opts[:live] -> run_live(opts)
      opts[:video] -> raise("--video is only supported with explicit --live")
      true -> run_offline(manifest, opts)
    end
  end

  defp run_offline(manifest, opts) do
    fixtures =
      Enum.filter(manifest["cases"], fn fixture ->
        is_nil(opts[:case]) or fixture["id"] == opts[:case]
      end)

    if fixtures == [], do: raise("No matching fixture")
    start_runtime!()

    cases = Enum.map(fixtures, &evaluate_fixture/1)
    url_checks = check_urls()
    passed = Enum.all?(cases, & &1.passed) and Enum.all?(url_checks, & &1.passed)

    report = %{
      mode: "offline_fixture_contract",
      generated_at: DateTime.utc_now(),
      pipeline: "DragNStamp.Submissions.Processor.process/2",
      fixture_provenance: manifest["description"],
      passed: passed,
      summary: %{
        cases: length(cases),
        passed: Enum.count(cases, & &1.passed),
        url_checks: length(url_checks),
        url_checks_passed: Enum.count(url_checks, & &1.passed)
      },
      semantic_quality:
        "NOT MEASURED: model responses and source media are synthetic; these results are not real-video success rates or model quality scores.",
      external_api_calls: 0,
      paid_cost_usd: 0,
      cases: cases,
      url_checks: url_checks
    }

    write_report(report, opts[:output] || "tmp/evals/production_baseline.json")

    IO.puts(
      "Offline production baseline: #{report.summary.passed}/#{length(cases)} cases, #{report.summary.url_checks_passed}/#{length(url_checks)} URL checks passed. Semantic quality: not measured."
    )

    if not passed, do: System.halt(1)
  end

  defp evaluate_fixture(fixture) do
    {:ok, state} = FixtureIO.start(fixture)

    try do
      rollback_case(fn ->
        timestamp = insert_timestamp(fixture)
        result = Processor.process(timestamp, FixtureIO.options(state))
        persisted = Repo.get!(Timestamp, timestamp.id)
        snapshot = FixtureIO.snapshot(state)
        report = observed_result(result, persisted, snapshot)
        checks = fixture_checks(fixture, report, snapshot)

        report
        |> Map.merge(%{
          id: fixture["id"],
          strata: fixture["strata"],
          expected_route: fixture["expected_route"],
          expected_outcome: fixture["expected_outcome"],
          passed: Enum.all?(checks, & &1.passed),
          checks: checks
        })
      end)
    rescue
      error ->
        %{
          id: fixture["id"],
          passed: false,
          outcome: "harness_error",
          error: Exception.format(:error, error, __STACKTRACE__)
        }
    after
      Agent.stop(state)
    end
  end

  defp observed_result(result, persisted, snapshot) do
    {outcome, failure} =
      case result do
        {:ok, %Timestamp{}} -> {"ready", nil}
        {:error, error} -> {"error", error}
      end

    video_requests = Enum.count(snapshot.requests, &(&1.stage == :video))

    actual_route =
      cond do
        video_requests > 0 and snapshot.caption_fetches > 0 -> "video_then_captions"
        video_requests > 0 -> "video"
        snapshot.caption_fetches > 0 -> "captions"
        snapshot.fixture["checkpoint_content"] -> "resume_checkpoint"
        true -> "none"
      end

    content = persisted.distilled_content || persisted.content || ""
    timestamps = FixtureIO.timecodes(content)

    %{
      outcome: outcome,
      persisted_status: to_string(persisted.processing_status),
      persisted_phase: persisted.processing_phase,
      reason: if(failure, do: to_string(Map.get(failure, :reason, :unknown))),
      retryable: if(failure, do: Map.get(failure, :retryable)),
      actual_route: actual_route,
      requests: %{
        video: video_requests,
        caption: Enum.count(snapshot.requests, &(&1.stage == :caption)),
        distillation: Enum.count(snapshot.requests, &(&1.stage == :text)),
        caption_fetch: snapshot.caption_fetches
      },
      retry_delays_ms: Enum.reverse(snapshot.sleeps),
      final_timestamp_count: length(timestamps),
      final_first_seconds: List.first(timestamps),
      final_last_seconds: List.last(timestamps),
      content: content,
      processing_context: persisted.processing_context,
      primary_fallback:
        is_binary(persisted.content) and persisted.content != "" and
          persisted.distilled_content in [nil, ""]
    }
  end

  defp fixture_checks(fixture, report, snapshot) do
    caption_prompts =
      snapshot.requests |> Enum.filter(&(&1.stage == :caption)) |> Enum.map(& &1.prompt)

    combined = Enum.join(caption_prompts, "\n")
    segments = FixtureIO.segments(fixture["caption_profile"])

    represented =
      Regex.scan(~r/SYNTH_SEGMENT_(\d+)/, combined)
      |> Enum.map(fn [_, id] -> String.to_integer(id) end)
      |> MapSet.new()

    times = FixtureIO.timecodes(report.content)

    checks = [
      check(
        "production_route",
        report.actual_route == fixture["expected_route"],
        report.actual_route
      ),
      check("expected_outcome", report.outcome == fixture["expected_outcome"], report.outcome)
    ]

    checks =
      if report.outcome == "ready" do
        bound = fixture["duration_seconds"] || div(List.last(segments).end_ms, 1000)

        checks ++
          [
            check("persisted_ready", report.persisted_status == "ready", report.persisted_status),
            check("usable_timestamps", times != [], length(times)),
            check(
              "strictly_increasing",
              Enum.all?(Enum.chunk_every(times, 2, 1, :discard), fn [a, b] -> a < b end),
              times
            ),
            check("within_source_duration", Enum.all?(times, &(&1 >= 0 and &1 <= bound)), bound),
            check(
              "distillation_receives_duration_bound",
              snapshot.requests
              |> Enum.filter(&(&1.stage == :text))
              |> Enum.all?(&(&1.max_seconds == bound)),
              bound
            )
          ]
      else
        checks ++
          [
            check(
              "generation_failure_does_not_publish_a_result",
              report.persisted_status != "ready" and report.content == "",
              report.persisted_status
            )
          ]
      end

    checks
    |> optional_check(fixture["expected_reason"], "failure_category", report.reason)
    |> optional_check(fixture["expected_retryable"], "retry_classification", report.retryable)
    |> optional_check(
      fixture["expected_video_requests"],
      "video_retry_count",
      report.requests.video
    )
    |> maybe_check(
      fixture["require_primary_fallback"],
      check(
        "primary_retained_after_distillation_failure",
        report.primary_fallback,
        report.primary_fallback
      )
    )
    |> maybe_check(
      fixture["min_last_timestamp"],
      check(
        "late_timeline_survives",
        is_integer(report.final_last_seconds) and
          report.final_last_seconds >= (fixture["min_last_timestamp"] || 0),
        report.final_last_seconds
      )
    )
    |> maybe_check(
      fixture["require_all_segments"],
      check(
        "every_caption_segment_reaches_summarizer",
        represented == MapSet.new(0..(length(segments) - 1)),
        %{source_segments: length(segments), represented_segments: MapSet.size(represented)}
      )
    )
    |> maybe_check(
      fixture["required_prompt_text"],
      check(
        "multilingual_text_preserved",
        Enum.all?(fixture["required_prompt_text"] || [], &String.contains?(combined, &1)),
        fixture["required_prompt_text"]
      )
    )
  end

  defp check(name, passed, observed), do: %{name: name, passed: passed, observed: observed}
  defp optional_check(checks, nil, _name, _observed), do: checks

  defp optional_check(checks, expected, name, observed),
    do: checks ++ [check(name, expected == observed, observed)]

  defp maybe_check(checks, condition, check),
    do: if(condition, do: checks ++ [check], else: checks)

  defp check_urls do
    manifest = read_json("url_contract.json")

    Enum.map(manifest["valid"], fn url ->
      result = URL.parse(url)

      %{
        url: url,
        expected: "canonical",
        passed: result == {:ok, %{video_id: "_NlOIjOByUg", url: manifest["canonical_url"]}}
      }
    end) ++
      Enum.map(manifest["invalid"], fn url ->
        %{url: url, expected: "rejected", passed: URL.parse(url) == {:error, :invalid_url}}
      end)
  end

  defp insert_timestamp(fixture) do
    {:ok, identity} = URL.parse(fixture["url"])

    %Timestamp{}
    |> Timestamp.changeset(%{
      url: identity.url,
      video_id: identity.video_id,
      channel_name: fixture["channel_name"] || "Synthetic offline eval",
      video_duration_seconds: fixture["duration_seconds"],
      content: fixture["checkpoint_content"],
      processing_status: :processing
    })
    |> Repo.insert!()
  end

  defp rollback_case(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    try do
      {:error, {:eval_result, result}} =
        Repo.transaction(fn -> Repo.rollback({:eval_result, fun.()}) end)

      result
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defp start_runtime! do
    if Mix.env() != :test,
      do: raise("Eval requires MIX_ENV=test and an isolated local test database")

    config = Application.fetch_env!(:drag_n_stamp, Repo)

    unless config[:hostname] in ["localhost", "127.0.0.1", "::1"] and
             String.starts_with?(config[:database] || "", "drag_n_stamp_test"),
           do: raise("Eval refuses a non-local or non-test database")

    if Process.whereis(DragNStamp.Supervisor),
      do: raise("Use mix run --no-start so background application workers stay disabled")

    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, _} =
      Supervisor.start_link([Repo, {Phoenix.PubSub, name: DragNStamp.PubSub}],
        strategy: :one_for_one
      )

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
  end

  defp run_live(opts) do
    unless System.get_env("STAMPBOT_EVAL_ALLOW_LIVE") == "1",
      do:
        raise(
          "Live mode may incur API charges; explicitly set STAMPBOT_EVAL_ALLOW_LIVE=1 and choose --video VIDEO_ID"
        )

    unless is_binary(opts[:video]),
      do: raise("Live mode requires --video VIDEO_ID from the historical cohort")

    cohort = read_json("historical_video_cohort.json")

    video =
      Enum.find(cohort["videos"], &(&1["id"] == opts[:video])) ||
        raise("Video is not in the historical cohort")

    key = System.fetch_env!("GEMINI_API_KEY")
    if key == "", do: raise("GEMINI_API_KEY is empty")
    start_runtime!()
    Application.put_env(:drag_n_stamp, :fetch_video_metadata_on_ingest, true)
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Finch.start_link(name: DragNStamp.Finch)
    started = System.monotonic_time(:millisecond)

    report =
      rollback_case(fn ->
        # Refresh metadata via the production adapter; old snapshot durations are not presumed current.
        timestamp =
          insert_timestamp(%{
            "url" => "https://www.youtube.com/watch?v=#{video["id"]}",
            "channel_name" => video["channel"],
            "duration_seconds" => nil
          })

        result = Processor.process(timestamp, api_key: key, publish: false)
        persisted = Repo.get!(Timestamp, timestamp.id)

        %{
          mode: "live_production_pipeline",
          video_id: video["id"],
          historical_expected_route: video["expected_route"],
          result: inspect(result, limit: 5),
          processing_status: persisted.processing_status,
          processing_error: persisted.processing_error,
          processing_context: persisted.processing_context,
          content: persisted.distilled_content || persisted.content,
          estimated_retained_result_cost_usd:
            if(persisted.estimated_cost_usd, do: Decimal.to_string(persisted.estimated_cost_usd)),
          semantic_quality:
            "UNREVIEWED: a human must check source evidence and chapter boundaries",
          cost_scope:
            "PARTIAL: excludes failed/discarded attempts, including successful chunks from failed pipeline runs; missing usage or rates leave total cost unknown",
          database_changes: "row writes rolled back; PostgreSQL sequences may advance",
          publication: "disabled",
          duration_ms: System.monotonic_time(:millisecond) - started
        }
      end)

    write_report(report, opts[:output] || "tmp/evals/live_#{video["id"]}.json")

    IO.puts(
      "Live production run recorded for human review. Database changes rolled back; publication disabled."
    )
  end

  defp read_json(name),
    do: @root |> Path.join("fixtures/#{name}") |> File.read!() |> Jason.decode!()

  defp write_report(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("Report: #{Path.expand(path)}")
  end
end

StampBot.Evals.ProductionBaseline.run(System.argv())
