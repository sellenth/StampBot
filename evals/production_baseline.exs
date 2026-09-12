# Run with MIX_ENV=test mix run --no-start evals/production_baseline.exs
Code.require_file("support/fixture_io.exs", __DIR__)

defmodule StampBot.Evals.ProductionBaseline do
  @moduledoc false
  alias DragNStamp.{ProcessingAttempts, Repo, Timestamp}
  alias DragNStamp.Submissions.Processor
  alias DragNStamp.SEO.StaticPageRenderer
  alias DragNStamp.YouTube.URL
  alias StampBot.Evals.FixtureIO

  @root __DIR__

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          case: :string,
          list: :boolean,
          live: :boolean,
          video: :string,
          cohort: :string
        ]
      )

    if rest != [] or invalid != [],
      do: raise("Unknown eval arguments: #{inspect(rest ++ invalid)}")

    manifest = read_json("production_baseline.json")

    cond do
      opts[:list] -> Enum.each(manifest["cases"], &IO.puts(&1["id"]))
      opts[:live] -> run_live(opts)
      opts[:video] -> raise("--video is only supported with explicit --live")
      opts[:cohort] -> raise("--cohort is only supported with explicit --live")
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
      pipeline_source_sha256: pipeline_fingerprint(),
      fixture_provenance: manifest["description"],
      passed: passed,
      summary: %{
        cases: length(cases),
        passed: Enum.count(cases, & &1.passed),
        url_checks: length(url_checks),
        url_checks_passed: Enum.count(url_checks, & &1.passed),
        completed_pipelines: Enum.count(cases, &(Map.get(&1, :outcome) == "ready")),
        structurally_valid_outputs:
          Enum.count(cases, &get_in(&1, [:outcomes, :chapters, :structurally_valid]))
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

        result =
          with_work_budget(fixture, fn ->
            Processor.process(timestamp, FixtureIO.options(state))
          end)

        persisted = Repo.get!(Timestamp, timestamp.id)
        snapshot = FixtureIO.snapshot(state)
        report = observed_result(result, persisted, snapshot)
        report = Map.put(report, :safe_rendering, safe_rendering?(persisted, fixture))
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
        (persisted.processing_context || %{})["video_fallback_trigger"] != nil ->
          "captions_then_video"

        video_requests > 0 and snapshot.caption_fetches > 0 ->
          "video_then_captions"

        video_requests > 0 ->
          "video"

        snapshot.caption_fetches > 0 ->
          "captions"

        snapshot.fixture["checkpoint_content"] ->
          "resume_checkpoint"

        true ->
          "none"
      end

    content = persisted.distilled_content || persisted.content || ""
    timestamps = FixtureIO.timecodes(content)
    has_unwatched = Regex.match?(~r/\bUNWATCHED\b/i, content)

    bound =
      persisted.video_duration_seconds ||
        get_in(persisted.processing_context || %{}, ["output_bound_seconds"])

    structurally_valid =
      timestamps != [] and not has_unwatched and
        Enum.all?(Enum.chunk_every(timestamps, 2, 1, :discard), fn [a, b] -> a < b end) and
        is_integer(bound) and Enum.all?(timestamps, &(&1 >= 0 and &1 <= bound))

    attempts = ProcessingAttempts.for_timestamp(persisted.id)
    requests = Enum.filter(attempts, &(&1.kind == :request))
    costs = ProcessingAttempts.cost_summary(persisted.id)

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
      outcomes: %{
        acquisition: %{
          captions: if(snapshot.captions_acquired, do: "fixture_acquired", else: "not_acquired"),
          video_source_access: "not_independently_measured_by_offline_transport"
        },
        completion: %{
          generation: is_binary(persisted.content) and persisted.content != "",
          distillation:
            is_binary(persisted.distilled_content) and persisted.distilled_content != "",
          successful_model_calls: Enum.count(snapshot.model_results, &(&1.status == :completed)),
          pipeline_ready: outcome == "ready"
        },
        chapters: %{
          structurally_valid: structurally_valid,
          contains_unwatched: has_unwatched,
          usable_for_viewers: if(structurally_valid, do: "unreviewed", else: "no"),
          factual_quality: "not_measured",
          boundary_quality: "not_measured"
        }
      },
      attempt_ledger: %{
        total_spans: length(attempts),
        running_spans: Enum.count(attempts, &(&1.status == :running)),
        request_rows: length(requests),
        dispatched_requests: costs.request_count,
        requests_with_reported_usage: Enum.count(requests, &(&1.usage_status == :reported)),
        failed_requests_with_reported_usage:
          Enum.count(requests, &(&1.status == :failed and &1.usage_status == :reported)),
        requests_with_unknown_usage:
          Enum.count(
            requests,
            &(&1.dispatched and &1.usage_status == :not_reported and is_nil(&1.prompt_tokens))
          ),
        blocked_requests:
          Enum.count(
            requests,
            &(&1.dispatched == false and &1.failure_kind == "work_budget_exceeded")
          ),
        blocked_requests_have_no_estimated_charge:
          requests
          |> Enum.filter(&(&1.dispatched == false and &1.failure_kind == "work_budget_exceeded"))
          |> Enum.all?(fn request ->
            request.cost_status == :not_dispatched and
              (is_nil(request.estimated_cost_usd) or Decimal.equal?(request.estimated_cost_usd, 0))
          end),
        unknown_cost_requests: costs.unknown_request_count,
        synthetic_estimated_cost_usd:
          if(costs.known_cost_usd, do: Decimal.to_string(costs.known_cost_usd)),
        cost_scope: "Synthetic fixture token counts only; actual paid cost is zero"
      },
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
      check("expected_outcome", report.outcome == fixture["expected_outcome"], report.outcome),
      check(
        "every_dispatched_request_is_in_attempt_ledger",
        report.attempt_ledger.dispatched_requests == length(snapshot.requests),
        %{ledger: report.attempt_ledger.dispatched_requests, transport: length(snapshot.requests)}
      ),
      check(
        "no_unfinished_spans_after_pipeline_returns",
        report.attempt_ledger.running_spans == 0,
        report.attempt_ledger.running_spans
      )
    ]

    checks =
      if report.outcome == "ready" do
        bound = fixture["duration_seconds"] || div(List.last(segments).end_ms, 1000)

        checks ++
          [
            check("persisted_ready", report.persisted_status == "ready", report.persisted_status),
            check(
              "valid_timestamp_format_and_bounds",
              report.outcomes.chapters.structurally_valid,
              length(times)
            ),
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
    |> optional_check(
      fixture["expected_caption_requests"],
      "caption_request_count",
      report.requests.caption
    )
    |> optional_check(
      fixture["expected_dispatched_requests"],
      "dispatched_request_limit",
      report.attempt_ledger.dispatched_requests
    )
    |> maybe_check(
      fixture["require_budget_denial"],
      check(
        "budget_denial_recorded_without_http_dispatch",
        report.attempt_ledger.blocked_requests > 0 and
          report.attempt_ledger.blocked_requests_have_no_estimated_charge,
        report.attempt_ledger.blocked_requests
      )
    )
    |> optional_check(
      fixture["expected_completed_chunks"],
      "completed_chunks_retained_in_failure_metadata",
      get_in(report.processing_context || %{}, [
        "caption_attempts",
        Access.at(0),
        "transcript_stats",
        "completed_chunk_count"
      ])
    )
    |> maybe_check(
      fixture["require_unknown_usage"],
      check(
        "missing_provider_usage_remains_unknown",
        report.attempt_ledger.requests_with_unknown_usage > 0 and
          report.attempt_ledger.unknown_cost_requests > 0,
        report.attempt_ledger.requests_with_unknown_usage
      )
    )
    |> maybe_check(
      fixture["require_failed_usage"],
      check(
        "provider_usage_survives_invalid_or_incomplete_output",
        report.attempt_ledger.failed_requests_with_reported_usage > 0,
        report.attempt_ledger.failed_requests_with_reported_usage
      )
    )
    |> maybe_check(
      fixture["require_untrusted_marker_separation"],
      check(
        "instruction_marker_only_in_user_data_not_system_instruction",
        String.contains?(combined, "UNTRUSTED_FIXTURE_MARKER") and
          Enum.all?(snapshot.requests, fn request ->
            instruction = Jason.encode!(request.system_instruction)

            not String.contains?(instruction, "UNTRUSTED_FIXTURE_MARKER") and
              instruction != "null"
          end),
        "Mechanical role boundary only; model resistance is not measured"
      )
    )
    |> maybe_check(
      fixture["require_safe_rendering"],
      check(
        "untrusted_script_marker_is_html_encoded",
        report.safe_rendering,
        report.safe_rendering
      )
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

  defp safe_rendering?(timestamp, %{"require_safe_rendering" => true}) do
    html = StaticPageRenderer.render(timestamp)

    String.contains?(html, "FIXTURE_SCRIPT_MARKER") and
      not String.contains?(html, "</script><script>FIXTURE_SCRIPT_MARKER") and
      not String.contains?(html, "<script>FIXTURE_SCRIPT_MARKER")
  end

  defp safe_rendering?(_timestamp, _fixture), do: nil

  defp with_work_budget(%{"enable_work_budget" => true} = fixture, fun) do
    original = Application.get_env(:drag_n_stamp, :work_budget)
    config = Keyword.put(original || [], :enabled, true)

    config =
      if fixture["run_request_limit"],
        do: Keyword.put(config, :run_request_limit, fixture["run_request_limit"]),
        else: config

    Application.put_env(:drag_n_stamp, :work_budget, config)

    try do
      fun.()
    after
      if is_nil(original),
        do: Application.delete_env(:drag_n_stamp, :work_budget),
        else: Application.put_env(:drag_n_stamp, :work_budget, original)
    end
  end

  defp with_work_budget(_fixture, fun), do: fun.()
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
      # Sandbox already wraps all row writes and rolls them back on checkin.
      # An extra Repo.transaction would turn a handled budget denial's nested
      # Repo.rollback into an aborted outer transaction, unlike worker execution.
      fun.()
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
      do: raise("Live mode requires --video VIDEO_ID from the selected cohort")

    cohort =
      if opts[:cohort],
        do: opts[:cohort] |> File.read!() |> Jason.decode!(),
        else: read_json("historical_video_cohort.json")

    video =
      Enum.find(cohort["videos"], &((&1["video_id"] || &1["id"]) == opts[:video])) ||
        raise("Video is not in the selected cohort")

    video_id = video["video_id"] || video["id"]
    {:ok, identity} = URL.parse("https://www.youtube.com/watch?v=#{video_id}")

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
            "url" => identity.url,
            "channel_name" => video["channel"] || "Cohort evaluation",
            "duration_seconds" => nil
          })

        result =
          with_work_budget(%{"enable_work_budget" => true}, fn ->
            Processor.process(timestamp, api_key: key, publish: false)
          end)

        persisted = Repo.get!(Timestamp, timestamp.id)
        attempts = ProcessingAttempts.for_timestamp(timestamp.id)
        costs = ProcessingAttempts.cost_summary(timestamp.id)

        %{
          mode: "live_production_pipeline",
          generated_at: DateTime.utc_now(),
          pipeline_source_sha256: pipeline_fingerprint(),
          video_id: video_id,
          cohort_id: video["cohort_id"],
          split: video["split"] || "historical_unassigned",
          historical_expected_route: video["expected_route"],
          result: if(match?({:ok, _}, result), do: "ready", else: "error"),
          failure_category:
            case result do
              {:error, reason} -> ProcessingAttempts.failure_kind(reason)
              _ -> nil
            end,
          processing_status: persisted.processing_status,
          processing_context:
            Map.take(persisted.processing_context || %{}, [
              "generation_model",
              "output_bound_seconds",
              "distillation_failed"
            ]),
          content: persisted.distilled_content || persisted.content,
          attempts:
            Enum.map(
              attempts,
              fn attempt ->
                attempt
                |> Map.take(
                  ~w(id run_id parent_attempt_id kind stage status provider operation chunk_index request_attempt duration_ms failure_kind http_status dispatched model model_version thinking_level prompt_version schema_version provider_request_id finish_reason input_bytes start_seconds end_seconds prompt_tokens output_tokens thinking_tokens cached_tokens total_tokens usage_status cost_status)a
                )
                |> Map.put(
                  :estimated_cost_usd,
                  if(attempt.estimated_cost_usd,
                    do: Decimal.to_string(attempt.estimated_cost_usd)
                  )
                )
              end
            ),
          all_attempt_cost: %{
            known_estimated_usd:
              if(costs.known_cost_usd, do: Decimal.to_string(costs.known_cost_usd)),
            dispatched_requests: costs.request_count,
            unknown_cost_requests: costs.unknown_request_count,
            total_known: costs.unknown_request_count == 0
          },
          semantic_quality:
            "UNREVIEWED: a human must check source evidence and chapter boundaries",
          outcomes: %{
            acquisition:
              "Review stage records and source evidence; a completed video request alone does not verify video ingestion",
            pipeline_completed: match?({:ok, _}, result),
            distillation_completed:
              is_binary(persisted.distilled_content) and persisted.distilled_content != "",
            usable_chapters: "unreviewed"
          },
          cost_scope:
            "All dispatched request rows, including retries and rejected model output; missing usage or rates leave total cost unknown. Provider billing may differ from configured estimates.",
          database_changes: "row writes rolled back; PostgreSQL sequences may advance",
          publication: "disabled",
          duration_ms: System.monotonic_time(:millisecond) - started
        }
      end)

    write_report(report, opts[:output] || "tmp/evals/live_#{video_id}.json")

    IO.puts(
      "Live production run recorded for human review. Database changes rolled back; publication disabled."
    )
  end

  defp read_json(name),
    do: @root |> Path.join("fixtures/#{name}") |> File.read!() |> Jason.decode!()

  defp pipeline_fingerprint do
    root = Path.expand("..", @root)

    [Path.join(root, "mix.lock") | Path.wildcard(Path.join(root, "lib/**/*.ex"))]
    |> Enum.sort()
    |> Enum.map(fn path -> [Path.relative_to(path, root), <<0>>, File.read!(path), <<0>>] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_report(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("Report: #{Path.expand(path)}")
  end
end

StampBot.Evals.ProductionBaseline.run(System.argv())
