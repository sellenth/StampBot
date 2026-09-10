defmodule DragNStamp.Timestamps.CaptionRecoveryTest do
  use DragNStamp.DataCase, async: true

  alias DragNStamp.{ProcessingAttempts, Timestamp}
  alias DragNStamp.Timestamps.{CaptionCheckpoint, CaptionFallback, GeminiClient}

  test "production #593: an out-of-excerpt reply is retried, charged, and all five excerpts complete" do
    timestamp = timestamp()
    calls = :counters.new(1, [])
    parent = self()

    request = fn request, _ ->
      :counters.add(calls, 1, 1)
      body = Jason.decode!(request.body)

      bounds =
        get_in(body, [
          "generationConfig",
          "responseSchema",
          "properties",
          "timestamps",
          "items",
          "properties",
          "seconds"
        ])

      send(parent, {:body, body})
      seconds = if :counters.get(calls, 1) == 1, do: 1019, else: bounds["minimum"]
      response(seconds)
    end

    assert {:ok, content, meta} = run(timestamp, segments(), request)
    assert :counters.get(calls, 1) == 6
    assert content =~ "1:00:00"
    assert meta["transcript_stats"]["completed_chunk_count"] == 5
    assert meta["transcript_stats"]["reused_chunk_count"] == 0
    assert Repo.aggregate(CaptionCheckpoint, :count) == 5

    assert_receive {:body, first}

    assert get_in(first, [
             "generationConfig",
             "responseSchema",
             "properties",
             "timestamps",
             "items",
             "properties",
             "seconds",
             "maximum"
           ]) == 893

    assert_receive {:body, retry}
    assert Jason.encode!(retry["systemInstruction"]) =~ "between 0 and 893"

    [rejected | remaining] = requests(timestamp)
    assert rejected.failure_kind == "timestamp_out_of_bounds"
    assert rejected.status == :failed
    assert rejected.http_status == 200
    assert rejected.cost_status == :estimated
    assert Enum.all?(remaining, &(&1.status == :succeeded))
    total = ProcessingAttempts.cost_summary(timestamp.id)
    assert total.request_count == 6
    assert Decimal.equal?(total.known_cost_usd, Decimal.new(meta["estimated_cost_usd"]))
  end

  test "exhausted chunk validation is terminal after three requests and saves no invalid checkpoint" do
    timestamp = timestamp()
    calls = :counters.new(1, [])

    request = fn _, _ ->
      :counters.add(calls, 1, 1)
      response(1019)
    end

    assert {:error, :timestamp_outside_excerpt, message, meta} =
             run(timestamp, segments(), request)

    assert :counters.get(calls, 1) == 3
    assert message =~ "outside the excerpt"
    refute message =~ "saved the output"
    refute meta["retryable"]
    assert meta["transcript_stats"]["completed_chunk_count"] == 0
    assert Repo.aggregate(CaptionCheckpoint, :count) == 0
    assert length(requests(timestamp)) == 3

    assert Enum.all?(
             requests(timestamp),
             &(&1.status == :failed and &1.cost_status == :estimated)
           )
  end

  test "a restarted run reuses a successful excerpt and retains charges for a later failed excerpt" do
    timestamp = timestamp()

    request = fn request, _ ->
      minimum = minimum(request)

      if minimum == 0,
        do: response(0),
        else: {:ok, %Finch.Response{status: 503, headers: [], body: "{}"}}
    end

    assert {:error, :gemini_error, _, failed} = run(timestamp, Enum.take(segments(), 2), request)
    assert failed["transcript_stats"]["completed_chunk_count"] == 1
    assert failed["retryable"]
    assert length(requests(timestamp)) == 4
    assert Repo.aggregate(CaptionCheckpoint, :count) == 1

    request = fn request, _ ->
      assert minimum(request) == 900, "the first paid excerpt must not be generated again"
      response(900)
    end

    assert {:ok, content, recovered} = run(timestamp, Enum.take(segments(), 2), request)
    assert content =~ "0:00"
    assert content =~ "15:00"
    assert recovered["transcript_stats"]["reused_chunk_count"] == 1
    assert recovered["transcript_stats"]["completed_chunk_count"] == 2
    assert length(requests(timestamp)) == 5
    assert Repo.aggregate(CaptionCheckpoint, :count) == 2
    assert ProcessingAttempts.cost_summary(timestamp.id).unknown_request_count == 3
  end

  test "changed evidence invalidates a checkpoint and corrupt stored chapters are never reused" do
    timestamp = timestamp()
    source = Enum.take(segments(), 1)
    request = fn _, _ -> response(0) end
    assert {:ok, _, _} = run(timestamp, source, request)

    assert {:ok, _, meta} =
             run(timestamp, source, fn _, _ -> flunk("unchanged checkpoint should be reused") end)

    assert meta["transcript_stats"]["reused_chunk_count"] == 1

    changed = Enum.map(source, &Map.put(&1, :text, "Different evidence requires a fresh result."))
    assert {:ok, _, meta} = run(timestamp, changed, request)
    assert meta["transcript_stats"]["reused_chunk_count"] == 0

    Repo.update_all(CaptionCheckpoint,
      set: [chapter_data: [%{"seconds" => 1019, "title" => "Corrupt out of range result"}]]
    )

    assert {:ok, _, meta} = run(timestamp, changed, request)
    assert meta["transcript_stats"]["reused_chunk_count"] == 0
    assert length(requests(timestamp)) == 3
  end

  test "later excerpts reject a restarted zero clock inside the bounded client retry loop" do
    timestamp = timestamp()
    calls = :counters.new(1, [])

    request = fn _, _ ->
      :counters.add(calls, 1, 1)
      response(if(:counters.get(calls, 1) == 1, do: 0, else: 900))
    end

    assert {:ok, _, _} = run(timestamp, [Enum.at(segments(), 1)], request)
    assert :counters.get(calls, 1) == 2
    assert [failed, succeeded] = requests(timestamp)
    assert failed.failure_kind == "timestamp_outside_excerpt"
    assert succeeded.status == :succeeded
  end

  test "a hard process kill retains earlier checkpoints and recovery marks the interrupted request unknown" do
    timestamp = timestamp()
    {:ok, job} = Oban.insert(DragNStamp.Submissions.Worker.new(%{timestamp_id: timestamp.id}))
    parent = self()

    child =
      spawn(fn ->
        receive do
          :start ->
            run(
              timestamp,
              Enum.take(segments(), 2),
              fn request, _ ->
                if minimum(request) == 0 do
                  response(0)
                else
                  send(parent, :second_request_dispatched)

                  receive do
                    :never -> response(900)
                  end
                end
              end,
              %{job_id: job.id, job_attempt: 1}
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), child)
    monitor = Process.monitor(child)
    send(child, :start)
    assert_receive :second_request_dispatched, 5_000
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
    assert Repo.aggregate(CaptionCheckpoint, :count) == 1

    assert {:ok, _, meta} =
             run(
               timestamp,
               Enum.take(segments(), 2),
               fn request, _ ->
                 assert minimum(request) == 900
                 response(900)
               end,
               %{job_id: job.id, job_attempt: 2}
             )

    assert meta["transcript_stats"]["reused_chunk_count"] == 1
    assert [_, interrupted, completed] = requests(timestamp)
    assert interrupted.status == :interrupted
    assert interrupted.cost_status == :unknown
    assert completed.status == :succeeded
  end

  defp run(timestamp, segments, request, context \\ %{}) do
    ProcessingAttempts.with_run(
      Map.merge(%{timestamp_id: timestamp.id, job_attempt: 1}, context),
      fn _ ->
        CaptionFallback.process("Fixture", timestamp.url, "fixture-key",
          max_seconds: 4463,
          fetch_transcript_fun: fn _ ->
            {:ok, %{segments: segments, context: %{source: "fixture"}}}
          end,
          generate_fun: fn prompt, key, opts ->
            GeminiClient.text_only_detailed(
              prompt,
              key,
              Keyword.merge(opts,
                request_fun: request,
                max_attempts: 3,
                sleep_fun: fn _ -> :ok end
              )
            )
          end
        )
      end
    )
  end

  defp timestamp do
    Repo.insert!(%Timestamp{
      url: "https://www.youtube.com/watch?v=sLSTM9znQNs",
      channel_name: "Fixture",
      video_duration_seconds: 4463
    })
  end

  defp segments do
    for start <- [0, 900, 1800, 2700, 3600] do
      %{
        start_ms: start * 1000,
        end_ms: min(start + 893, 4463) * 1000,
        text: "Synthetic transcript evidence at original second #{start}."
      }
    end
  end

  defp minimum(request) do
    request.body
    |> Jason.decode!()
    |> get_in([
      "generationConfig",
      "responseSchema",
      "properties",
      "timestamps",
      "items",
      "properties",
      "seconds",
      "minimum"
    ])
  end

  defp response(seconds) do
    content =
      Jason.encode!(%{
        timestamps: [
          %{seconds: seconds, title: "The supplied evidence explains this part of the discussion"}
        ]
      })

    {:ok,
     %Finch.Response{
       status: 200,
       headers: [],
       body:
         Jason.encode!(%{
           candidates: [%{content: %{parts: [%{text: content}]}, finishReason: "STOP"}],
           modelVersion: "gemini-3.5-flash-lite",
           usageMetadata: %{promptTokenCount: 100, candidatesTokenCount: 20, totalTokenCount: 120}
         })
     }}
  end

  defp requests(timestamp),
    do: ProcessingAttempts.for_timestamp(timestamp.id) |> Enum.filter(&(&1.kind == :request))
end
