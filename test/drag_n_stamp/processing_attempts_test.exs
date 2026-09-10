defmodule DragNStamp.ProcessingAttemptsTest do
  use DragNStamp.DataCase, async: false

  alias DragNStamp.{Operations, ProcessingAttempts}
  alias DragNStamp.Submissions.{Processor, Worker}
  alias DragNStamp.Timestamps.{CaptionFallback, CostEstimator, GeminiClient}

  setup do
    budget = Application.get_env(:drag_n_stamp, :work_budget)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :work_budget, budget) end)
    :ok
  end

  test "rejected and superseded provider replies retain usage, linkage, versions, and costs" do
    timestamp = timestamp()
    {:ok, job} = timestamp.id |> then(&Worker.new(%{timestamp_id: &1})) |> Oban.insert()
    calls = :counters.new(1, [])

    request = fn _, _ ->
      :counters.add(calls, 1, 1)
      index = :counters.get(calls, 1)
      content = if index == 1, do: "PRIVATE_PROVIDER_PAYLOAD", else: valid_content()
      response(content, usage(index * 100, index * 20), "request-#{index}")
    end

    assert {:ok, result} =
             traced(
               timestamp,
               fn ->
                 GeminiClient.text_only_detailed("PRIVATE_TRANSCRIPT", "PRIVATE_API_KEY",
                   request_fun: request,
                   sleep_fun: fn _ -> :ok end,
                   max_attempts: 2,
                   prompt_version: "test-prompt-v1",
                   max_seconds: 180
                 )
               end,
               job_id: job.id
             )

    rows = ProcessingAttempts.for_timestamp(timestamp.id)
    requests = Enum.filter(rows, &(&1.kind == :request))
    assert [failed, succeeded] = requests
    assert failed.status == :failed
    assert failed.failure_kind == "invalid_model_output"
    assert failed.prompt_tokens == 100
    assert failed.output_tokens == 20
    assert failed.thinking_tokens == 10
    assert failed.provider_request_id == "request-1"
    assert succeeded.status == :succeeded
    assert succeeded.prompt_tokens == 200
    assert succeeded.provider_request_id == "request-2"
    assert Enum.all?(requests, &(&1.job_id == job.id and &1.job_attempt == 1))
    assert Enum.all?(requests, &(&1.model_version == "fixture-model-version"))

    assert Enum.all?(
             requests,
             &(&1.prompt_version == "test-prompt-v1" and &1.schema_version == "timestamps-v2")
           )

    assert Enum.all?(requests, &(&1.duration_ms >= 0 and &1.cost_status == :estimated))
    assert Enum.all?(rows, &(&1.status != :running))
    assert Enum.all?(requests, &(&1.parent_attempt_id == hd(rows).id))

    total = Decimal.add(failed.estimated_cost_usd, succeeded.estimated_cost_usd)
    summary = ProcessingAttempts.cost_summary(timestamp.id)
    assert summary.request_count == 2
    assert summary.unknown_request_count == 0
    assert Decimal.equal?(summary.known_cost_usd, total)
    assert Decimal.equal?(CostEstimator.estimate_usd(result), total)

    persisted =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT row_to_json(a)::text FROM processing_attempts a WHERE timestamp_id = $1",
        [timestamp.id]
      )
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> Enum.join()

    refute persisted =~ "PRIVATE_PROVIDER_PAYLOAD"
    refute persisted =~ "PRIVATE_TRANSCRIPT"
    refute persisted =~ "PRIVATE_API_KEY"
    assert ProcessingAttempts.context() == %{}
  end

  test "missing usage remains unknown while explicitly reported zero usage remains zero" do
    timestamp = timestamp()
    calls = :counters.new(1, [])

    request = fn _, _ ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1 do
        {:ok, %Finch.Response{status: 429, headers: [], body: ~s({"error":"PRIVATE_ERROR_BODY"})}}
      else
        response(valid_content(), usage(0, 0, 0), "zero-usage")
      end
    end

    assert {:ok, result} =
             traced(timestamp, fn ->
               GeminiClient.text_only_detailed("Fixture", "fixture-key",
                 request_fun: request,
                 sleep_fun: fn _ -> :ok end,
                 max_attempts: 2
               )
             end)

    [unknown, known_zero] = requests(timestamp)
    assert unknown.cost_status == :unknown
    assert unknown.usage_status == :not_reported
    assert unknown.estimated_cost_usd == nil
    assert unknown.prompt_tokens == nil
    assert known_zero.cost_status == :estimated
    assert known_zero.usage_status == :reported
    assert Decimal.equal?(known_zero.estimated_cost_usd, Decimal.new(0))
    assert result.unknown_cost_attempts == 1
    assert ProcessingAttempts.cost_summary(timestamp.id).unknown_request_count == 1
    assert CostEstimator.estimate_usage_usd("gemini-3.5-flash-lite", %{}) == nil
  end

  test "sentinel output and incomplete or refused responses are terminal and retain billed usage" do
    timestamp = timestamp()

    for {finish, content, failure} <- [
          {"STOP", valid_content("UNWATCHED"), :unwatched},
          {"MAX_TOKENS", valid_content(), :incomplete_output},
          {"SAFETY", valid_content(), :incomplete_output}
        ] do
      calls = :counters.new(1, [])

      request = fn _, _ ->
        :counters.add(calls, 1, 1)
        response(content, usage(100, 20), "rejected-#{finish}", finish)
      end

      assert {:error, %{kind: :invalid_model_output, reason: ^failure}} =
               traced(timestamp, fn ->
                 GeminiClient.text_only_detailed("Fixture", "fixture-key",
                   request_fun: request,
                   sleep_fun: fn _ -> :ok end,
                   max_attempts: 3
                 )
               end)

      assert :counters.get(calls, 1) == 1
    end

    assert length(requests(timestamp)) == 3

    assert Enum.all?(
             requests(timestamp),
             &(&1.status == :failed and &1.cost_status == :estimated)
           )
  end

  test "malformed candidate content returns a typed failure and retains reported usage" do
    timestamp = timestamp()

    for content <- ["malformed content", ["malformed content"], %{"parts" => "malformed"}] do
      assert {:error, %{kind: :invalid_model_output, reason: :missing_candidate_text}} =
               traced(timestamp, fn ->
                 GeminiClient.text_only_detailed("Fixture", "fixture-key",
                   max_attempts: 1,
                   request_fun: fn _, _ ->
                     {:ok,
                      %Finch.Response{
                        status: 200,
                        headers: [],
                        body:
                          Jason.encode!(%{
                            "candidates" => [%{"content" => content, "finishReason" => "STOP"}],
                            "usageMetadata" => usage(100, 20)
                          })
                      }}
                   end
                 )
               end)
    end

    assert length(requests(timestamp)) == 3
    assert Enum.all?(requests(timestamp), &(&1.status == :failed and &1.prompt_tokens == 100))
    assert Enum.all?(requests(timestamp), &(&1.cost_status == :estimated))
  end

  test "a legacy UNWATCHED checkpoint reacquires and regenerates before becoming ready" do
    timestamp = timestamp(%{content: "0:00 UNWATCHED", video_duration_seconds: 180})
    calls = :counters.new(2, [])

    generate = fn prompt, key, opts ->
      GeminiClient.text_only_detailed(
        prompt,
        key,
        Keyword.put(opts, :request_fun, fn _, _ ->
          response(valid_content(), usage(100, 20), "regenerated")
        end)
      )
    end

    assert {:ok, ready} =
             Processor.process(timestamp,
               api_key: "fixture-key",
               publish: false,
               metadata_fun: fn value ->
                 :counters.add(calls, 1, 1)
                 assert value.content == nil
                 {:ok, value}
               end,
               video_fun: fn prompt, key, _url, opts ->
                 :counters.add(calls, 2, 1)
                 generate.(prompt, key, opts)
               end,
               text_fun: generate
             )

    assert :counters.get(calls, 1) == 1
    assert :counters.get(calls, 2) == 1
    assert ready.processing_status == :ready
    refute ready.content =~ "UNWATCHED"
    refute ready.distilled_content =~ "UNWATCHED"
    assert ready.processing_context["model_request_count"] == 2
  end

  test "admission failures retain distinct bounded operator categories" do
    for reason <- [
          :caller_rate_limited,
          :video_cooldown,
          :daily_work_limit,
          :daily_budget_exceeded
        ] do
      assert ProcessingAttempts.failure_kind(%{reason: reason}) == Atom.to_string(reason)
    end

    assert ProcessingAttempts.failure_kind(%{
             kind: :invalid_model_output,
             reason: {:timestamps_not_strictly_increasing, 743, 102}
           }) == "timestamps_not_strictly_increasing"

    assert ProcessingAttempts.failure_kind("PRIVATE_ERROR_DETAIL") == "other"
  end

  test "budget denial creates an undispatched record and never invokes provider IO" do
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true)
    timestamp = timestamp()

    assert {:error, %{kind: :work_budget_exceeded}} =
             traced(timestamp, fn ->
               GeminiClient.text_only_detailed("Fixture", "fixture-key",
                 request_fun: fn _, _ ->
                   flunk("An unreserved request must never reach the provider")
                 end
               )
             end)

    assert [denied] = requests(timestamp)
    refute denied.dispatched
    assert denied.cost_status == :not_dispatched
    assert denied.failure_kind == "work_budget_exceeded"
    assert Decimal.equal?(denied.estimated_cost_usd, Decimal.new(0))
    assert ProcessingAttempts.cost_summary(timestamp.id).request_count == 0
  end

  test "an invalid excerpt cannot bypass the request budget through correction retries" do
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true, run_request_limit: 1)
    timestamp = timestamp()
    {:ok, reserved} = DragNStamp.WorkBudget.ensure_reservation(timestamp)
    calls = :counters.new(1, [])

    result =
      ProcessingAttempts.with_run(
        %{
          timestamp_id: timestamp.id,
          job_attempt: 1,
          reservation_id: reserved.processing_context["work_reservation_id"]
        },
        fn _ ->
          GeminiClient.text_only_detailed("Excerpt 0 through 893", "fixture-key",
            min_seconds: 0,
            max_seconds: 893,
            sleep_fun: fn _ -> :ok end,
            request_fun: fn _, _ ->
              :counters.add(calls, 1, 1)

              response(
                Jason.encode!(%{
                  timestamps: [%{seconds: 1019, title: "Outside the supplied excerpt"}]
                }),
                usage(100, 20),
                "rejected"
              )
            end
          )
        end
      )

    assert {:error, %{kind: :work_budget_exceeded}} = result
    assert :counters.get(calls, 1) == 1
    assert [rejected, denied] = requests(timestamp)
    assert rejected.dispatched and rejected.cost_status == :estimated
    refute denied.dispatched
    assert denied.cost_status == :not_dispatched
    assert ProcessingAttempts.cost_summary(timestamp.id).request_count == 1
  end

  test "production records discarded distillation costs alongside successful video generation" do
    timestamp = timestamp(%{video_duration_seconds: 180})
    video_calls = :counters.new(1, [])

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      ALTER TABLE timestamps ADD CONSTRAINT ready_requires_cost_summary CHECK (
        processing_status <> 'ready' OR (
          COALESCE((processing_context->>'model_request_count')::int, -1) = 4 AND
          COALESCE((processing_context->>'unknown_cost_requests')::int, -1) = 1 AND
          COALESCE((processing_context->>'cost_complete')::boolean, true) = false AND
          estimated_cost_usd IS NOT NULL
        )
      )
      """,
      []
    )

    opts = [
      api_key: "fixture-key",
      publish: false,
      metadata_fun: fn value -> {:ok, value} end,
      video_fun: fn prompt, key, url, opts ->
        GeminiClient.timestamps_detailed_with_retry(
          prompt,
          key,
          url,
          Keyword.merge(opts,
            sleep_fun: fn _ -> :ok end,
            request_fun: fn _, _ ->
              :counters.add(video_calls, 1, 1)

              if :counters.get(video_calls, 1) == 1 do
                {:ok, %Finch.Response{status: 429, headers: [], body: "{}"}}
              else
                response(valid_content(), usage(100, 20), "video")
              end
            end
          )
        )
      end,
      text_fun: fn prompt, key, opts ->
        GeminiClient.text_only_detailed(
          prompt,
          key,
          Keyword.merge(opts,
            max_attempts: 2,
            sleep_fun: fn _ -> :ok end,
            request_fun: fn _, _ -> response("invalid output", usage(100, 20), "distillation") end
          )
        )
      end
    ]

    assert {:ok, ready} = Processor.process(timestamp, opts)
    assert ready.processing_status == :ready
    assert ready.processing_context["distillation_failed"]
    assert ready.processing_context["model_request_count"] == 4
    refute ready.processing_context["cost_complete"]
    assert ready.processing_context["unknown_cost_requests"] == 1
    assert ready.distilled_content == nil

    summary = ProcessingAttempts.cost_summary(timestamp.id)
    assert summary.request_count == 4
    assert summary.unknown_request_count == 1
    assert Decimal.equal?(summary.known_cost_usd, ready.estimated_cost_usd)
    assert Enum.count(requests(timestamp), &(&1.status == :failed)) == 3
    assert Enum.all?(ProcessingAttempts.for_timestamp(timestamp.id), &(&1.status != :running))
  end

  test "late caption failures preserve completed and rejected chunk costs and outcomes" do
    timestamp = timestamp()

    segments =
      for index <- 0..99,
          do: %{
            start_ms: index * 20_000,
            end_ms: (index + 1) * 20_000,
            text: "Transcript evidence for segment #{index}."
          }

    calls = :counters.new(1, [])

    assert {:error, :timestamp_extraction_failed, _, meta} =
             traced(timestamp, fn ->
               CaptionFallback.process(nil, timestamp.url, "fixture-key",
                 max_seconds: 2_000,
                 fetch_transcript_fun: fn _ -> {:ok, %{segments: segments, context: %{}}} end,
                 generate_fun: fn prompt, key, opts ->
                   request = fn _, _ ->
                     :counters.add(calls, 1, 1)

                     content =
                       if :counters.get(calls, 1) == 1, do: valid_content(), else: "invalid"

                     response(content, usage(100, 20), "caption")
                   end

                   GeminiClient.text_only_detailed(
                     prompt,
                     key,
                     Keyword.merge(opts, request_fun: request, max_attempts: 1)
                   )
                 end
               )
             end)

    assert meta["transcript_stats"]["completed_chunk_count"] == 1
    chunks = ProcessingAttempts.for_timestamp(timestamp.id) |> Enum.filter(&(&1.kind == :chunk))
    assert Enum.map(chunks, &{&1.chunk_index, &1.status}) == [{1, :succeeded}, {2, :failed}]
    summary = ProcessingAttempts.cost_summary(timestamp.id)
    assert summary.request_count == 2
    assert Decimal.equal?(summary.known_cost_usd, Decimal.new(meta["estimated_cost_usd"]))
  end

  test "a late ledger failure cannot downgrade a durable ready result" do
    timestamp = timestamp(%{content: "0:00 The opening explains the central idea"})
    {:ok, job} = timestamp.id |> then(&Worker.new(%{timestamp_id: &1})) |> Oban.insert()
    previous_opts = Application.get_env(:drag_n_stamp, :submission_processor_options)

    on_exit(fn ->
      if previous_opts do
        Application.put_env(:drag_n_stamp, :submission_processor_options, previous_opts)
      else
        Application.delete_env(:drag_n_stamp, :submission_processor_options)
      end
    end)

    Application.put_env(:drag_n_stamp, :submission_processor_options,
      api_key: "fixture-key",
      publish: false,
      text_fun: fn prompt, key, opts ->
        result =
          GeminiClient.text_only_detailed(
            prompt,
            key,
            Keyword.put(opts, :request_fun, fn _, _ ->
              response(valid_content(), usage(100, 20), "late-ledger-error")
            end)
          )

        # The run's final bookkeeping will now raise after the ready transaction
        # commits. Request usage survives because child links are nullified.
        Repo.delete_all(
          from(a in DragNStamp.ProcessingAttempt,
            where: a.timestamp_id == ^timestamp.id and a.kind == :run
          )
        )

        result
      end
    )

    assert :ok = Worker.perform(%{Repo.get!(Oban.Job, job.id) | attempt: 1})
    ready = Repo.get!(DragNStamp.Timestamp, timestamp.id)
    assert ready.processing_status == :ready
    assert ready.processing_phase == "ready"
    assert ready.processing_context["model_request_count"] == 1
    assert ready.processing_context["cost_complete"]
    assert ready.processing_context["last_failure"] == nil
    assert ready.distilled_content =~ "Timestamps by StampBot"
    assert Decimal.equal?(ready.estimated_cost_usd, hd(requests(timestamp)).estimated_cost_usd)
  end

  test "hard caption limits remain terminal after a transient direct-video failure" do
    timestamp = timestamp(%{video_duration_seconds: 180})

    for reason <- [:input_limit_exceeded, :work_budget_exceeded] do
      assert {:error, %{reason: ^reason, retryable: false}} =
               Processor.process(timestamp,
                 api_key: "fixture-key",
                 publish: false,
                 metadata_fun: fn value -> {:ok, value} end,
                 video_fun: fn _, _, _, _ -> {:error, %{kind: :transport}} end,
                 caption_fun: fn _, _, _, _ -> {:error, reason, "Limit reached", %{}} end
               )
    end
  end

  test "operator summaries expose unknown costs, queue age, and uncertain publication without payloads" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    timestamp =
      timestamp(%{
        youtube_comment_status: :pending,
        youtube_comment_last_attempt_at: DateTime.add(now, -180, :second)
      })

    {:ok, job} = timestamp.id |> then(&Worker.new(%{timestamp_id: &1})) |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [inserted_at: DateTime.add(now, -600, :second)]
    )

    traced(
      timestamp,
      fn ->
        GeminiClient.text_only_detailed("PRIVATE_PROMPT", "PRIVATE_KEY",
          request_fun: fn _, _ -> response(valid_content(), %{}, "unknown") end
        )
      end,
      job_id: job.id
    )

    report = Operations.snapshot(now: DateTime.add(now, 1, :second))
    assert report.unknown_cost_request_count == 1
    assert report.known_estimated_cost_usd == nil
    assert report.uncertain_publishing_count == 1
    assert [%{timestamp_id: id}] = report.uncertain_publishing
    assert id == timestamp.id
    assert Enum.any?(report.queues, &(&1.queue == "submissions" and &1.oldest_age_seconds >= 600))
    assert report.work_allowances.accounting_note =~ "not a provider billing cap"
    refute Jason.encode!(report) =~ "PRIVATE"
  end

  defp timestamp(attrs \\ %{}) do
    video_id =
      :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false) |> String.slice(0, 11)

    %DragNStamp.Timestamp{}
    |> DragNStamp.Timestamp.changeset(
      Map.merge(
        %{
          url: "https://www.youtube.com/watch?v=#{video_id}",
          video_id: video_id,
          channel_name: "Fixture",
          processing_status: :processing
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp traced(timestamp, fun, opts \\ []) do
    ProcessingAttempts.with_run(
      %{timestamp_id: timestamp.id, job_id: opts[:job_id], job_attempt: 1, reservation_id: nil},
      fn _ -> fun.() end
    )
  end

  defp requests(timestamp),
    do: ProcessingAttempts.for_timestamp(timestamp.id) |> Enum.filter(&(&1.kind == :request))

  defp valid_content(title \\ "The opening explains the central idea and planned demonstration"),
    do: Jason.encode!(%{timestamps: [%{seconds: 0, title: title}]})

  defp usage(prompt, output, thinking \\ 10),
    do: %{
      "promptTokenCount" => prompt,
      "candidatesTokenCount" => output,
      "thoughtsTokenCount" => thinking,
      "totalTokenCount" => prompt + output + thinking
    }

  defp response(content, usage, id, finish \\ "STOP") do
    {:ok,
     %Finch.Response{
       status: 200,
       headers: [{"x-request-id", id}],
       body:
         Jason.encode!(%{
           "candidates" => [
             %{"content" => %{"parts" => [%{"text" => content}]}, "finishReason" => finish}
           ],
           "usageMetadata" => usage,
           "modelVersion" => "fixture-model-version"
         })
     }}
  end
end
