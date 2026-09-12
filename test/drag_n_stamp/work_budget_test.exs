defmodule DragNStamp.WorkBudgetTest do
  use DragNStamp.DataCase, async: false
  alias DragNStamp.{Repo, Submissions, Timestamp, WorkBudget}
  alias DragNStamp.WorkBudget.{Day, Reservation}

  setup do
    previous = Application.get_env(:drag_n_stamp, :work_budget)
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true, caller_hourly_limit: 20)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :work_budget, previous) end)
    :ok
  end

  test "canonical duplicates and cached results consume a single reservation" do
    assert {:ok, ts, :created} = submit("budget00001")
    assert {:ok, same, :existing} = Submissions.submit("https://youtu.be/budget00001?t=5")
    assert ts.id == same.id
    assert Repo.aggregate(Reservation, :count) == 1
    Submissions.update!(ts, %{processing_status: :ready, content: "0:00 Intro"})
    set_config(daily_budget_microusd: 1)
    assert {:ok, cached, :existing} = submit("budget00001")
    assert cached.processing_status == :ready
    assert Repo.aggregate(Reservation, :count) == 1
  end

  test "caller limits cannot be avoided by changing submitter names" do
    set_config(caller_hourly_limit: 1)

    assert {:ok, _ts, :created} =
             Submissions.submit(url("budget00001"), %{submitter_username: "a"},
               caller_hash: "same-peer"
             )

    assert {:error, :caller_rate_limited} =
             Submissions.submit(url("budget00002"), %{submitter_username: "b"},
               caller_hash: "same-peer"
             )

    assert Repo.aggregate(Timestamp, :count) == 1
    assert Repo.aggregate(Reservation, :count) == 1
  end

  test "failed resubmission and manual retries obey the video cooldown without losing results" do
    assert {:ok, ts, :created} = submit("budget00001")
    Repo.update_all(Oban.Job, set: [state: "cancelled"])
    failed = Submissions.update!(ts, %{processing_status: :failed, content: "0:00 UNWATCHED"})
    assert {:error, :video_cooldown} = submit("budget00001")
    assert {:error, :video_cooldown} = Submissions.retry(failed)
    assert Repo.get!(Timestamp, ts.id).content == "0:00 UNWATCHED"
    refute (Repo.get!(Timestamp, ts.id).processing_context || %{})["manual_retry_used"]
    old = DateTime.add(DateTime.utc_now(), -3601, :second)
    Repo.update_all(Reservation, set: [inserted_at: old])
    assert {:ok, retried} = Submissions.retry(failed)
    assert retried.processing_context["manual_retry_used"]
    assert Repo.aggregate(Reservation, :count) == 2
  end

  test "a rejected budget reservation rolls back both the record and job" do
    set_config(daily_budget_microusd: 1_500_000)
    assert {:ok, _ts, :created} = submit("budget00001")
    assert {:error, :daily_budget_exceeded} = submit("budget00002")
    assert Repo.aggregate(Timestamp, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert Repo.get!(Day, Date.utc_today()).reserved_microusd == 1_500_000
  end

  test "each dispatched attempt consumes allowance and limits cannot be exceeded" do
    set_config(run_request_limit: 2)
    {:ok, ts, :created} = submit("budget00001")
    context = context(ts)
    assert :ok = WorkBudget.before_request(Map.put(context, :operation, :video))
    assert :ok = WorkBudget.before_request(Map.put(context, :operation, :text))
    assert {:error, :work_budget_exceeded} = WorkBudget.before_request(context)
    day = Repo.get!(Day, Date.utc_today())
    assert day.request_count == 2
    assert day.reserved_microusd == 2_000_000
    assert Repo.get!(Reservation, context.reservation_id).request_count == 2
    assert {:error, :work_budget_exceeded} = WorkBudget.before_request(%{timestamp_id: ts.id})
    assert {:error, :work_budget_exceeded} = WorkBudget.before_request(%{})
    assert {:error, :work_budget_exceeded} = WorkBudget.before_request(nil)

    assert {:error, :work_budget_exceeded} =
             WorkBudget.before_request(%{context | timestamp_id: ts.id + 1})
  end

  test "total allowance includes previous days and rejected admissions leave no record or job" do
    set_config(total_budget_microusd: 3_000_000)
    yesterday = Date.add(Date.utc_today(), -1)
    Repo.insert!(%Day{day: yesterday, reserved_microusd: 1_500_000})
    assert {:ok, ts, :created} = submit("budget00001")
    assert {:error, :total_budget_exceeded} = submit("budget00002")
    assert WorkBudget.total_reserved_microusd() == 3_000_000
    assert Repo.aggregate(Timestamp, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1

    # Paid work already reserved fits the ceiling, but a top-up cannot exceed it.
    assert :ok = WorkBudget.before_request(Map.put(context(ts), :operation, :video))
    assert {:error, :total_budget_exceeded} = WorkBudget.before_request(context(ts))
    assert Repo.get!(Reservation, context(ts).reservation_id).request_count == 1

    Submissions.update!(Repo.get!(Timestamp, ts.id), %{
      processing_status: :ready,
      content: "0:00 Intro"
    })

    assert {:ok, %{processing_status: :ready}, :existing} = submit("budget00001")
    assert WorkBudget.total_reserved_microusd() == 3_000_000

    # Removing a submission does not refund its allowance or reopen admissions.
    Repo.delete!(Repo.get!(Timestamp, ts.id))
    assert WorkBudget.total_reserved_microusd() == 3_000_000
    assert {:error, :total_budget_exceeded} = submit("budget00003")
  end

  test "crossing UTC midnight cannot restore a spent total allowance" do
    set_config(total_budget_microusd: 1_500_000)
    {:ok, ts, :created} = submit("budget00001")
    yesterday = Date.add(Date.utc_today(), -1)
    Repo.update_all(Day, set: [day: yesterday])
    Repo.update_all(Reservation, set: [allowance_day: yesterday])
    assert {:error, :total_budget_exceeded} = WorkBudget.before_request(context(ts))
    assert WorkBudget.total_reserved_microusd() == 1_500_000
    assert Repo.get!(Reservation, context(ts).reservation_id).request_count == 0
  end

  test "daily request cap is shared across reservations and retries" do
    set_config(daily_request_limit: 1)
    {:ok, a, :created} = submit("budget00001")
    {:ok, b, :created} = submit("budget00002")
    assert :ok = WorkBudget.before_request(context(a))
    assert {:error, :work_budget_exceeded} = WorkBudget.before_request(context(b))
    assert Repo.get!(Day, Date.utc_today()).request_count == 1
  end

  test "a carried job consumes today's allowance rather than expired prepaid work" do
    {:ok, ts, :created} = submit("budget00001")
    context = context(ts)
    Repo.update_all(Reservation, set: [allowance_day: Date.add(Date.utc_today(), -1)])
    assert :ok = WorkBudget.before_request(Map.put(context, :operation, :video))
    assert Repo.get!(Day, Date.utc_today()).reserved_microusd == 3_000_000
    assert Repo.get!(Reservation, context.reservation_id).remaining_microusd == 0
  end

  test "legacy jobs obtain one reservation before paid processing" do
    ts =
      %Timestamp{}
      |> Timestamp.changeset(%{
        url: url("budget00001"),
        video_id: "budget00001",
        channel_name: "test"
      })
      |> Repo.insert!()

    assert {:ok, updated} = WorkBudget.ensure_reservation(ts)
    assert updated.processing_context["work_reservation_id"]
    assert {:ok, again} = WorkBudget.ensure_reservation(ts)
    assert again.processing_context == updated.processing_context
    assert Repo.aggregate(Reservation, :count) == 1
  end

  test "oversized input fails before provider work" do
    assert {:error, :input_limit_exceeded} = WorkBudget.check_duration(%{}, 21_601)
    assert {:error, :input_limit_exceeded} = WorkBudget.check_chunks(%{}, 25)

    assert {:error, :input_limit_exceeded} =
             WorkBudget.check_request(%{}, %{text: String.duplicate("x", 262_144)})

    assert {:error, :input_limit_exceeded} =
             WorkBudget.check_transcript(%{}, [
               %{text: String.duplicate("x", 2_000_001), end_ms: 1000}
             ])

    assert {:error, :input_limit_exceeded} =
             WorkBudget.check_transcript(%{}, [%{text: "valid", end_ms: 21_601_000}])

    assert :ok = WorkBudget.check_transcript(%{}, [%{text: "valid", end_ms: nil}])

    assert {:error, :invalid_input} =
             Submissions.submit(url("budget00001"), %{
               submitter_username: String.duplicate("x", 201)
             })

    assert Repo.aggregate(Reservation, :count) == 0
  end

  test "caption-to-video fallback cannot dispatch when its allowance is exhausted" do
    {:ok, ts, :created} = submit("budget00001")
    ts = Submissions.update!(ts, %{video_duration_seconds: 1328})
    # Exhaust both the existing allowance and the cumulative top-up capacity.
    assert :ok = WorkBudget.before_request(Map.put(context(ts), :operation, :video))
    set_config(total_budget_microusd: 1_500_000)

    assert {:error, %{reason: :total_budget_exceeded, retryable: false}} =
             DragNStamp.Submissions.Processor.process(ts,
               api_key: "fixture-key",
               metadata_fun: fn ts -> {:ok, ts} end,
               caption_fun: fn _, _, _, _ ->
                 {:error, :youtube_bot_challenge, "YouTube blocked captions.", %{}}
               end,
               video_fun: fn prompt, key, url, opts ->
                 DragNStamp.Timestamps.GeminiClient.timestamps_detailed_with_retry(
                   prompt,
                   key,
                   url,
                   Keyword.put(opts, :request_fun, fn _, _ ->
                     flunk("budget denial must prevent HTTP dispatch")
                   end)
                 )
               end
             )

    assert Repo.get!(Reservation, context(ts).reservation_id).request_count == 1

    blocked =
      Repo.one!(
        from a in DragNStamp.ProcessingAttempt,
          where: a.timestamp_id == ^ts.id and a.kind == :request
      )

    refute blocked.dispatched
    assert blocked.cost_status == :not_dispatched
  end

  defp submit(id), do: Submissions.submit(url(id))
  defp url(id), do: "https://www.youtube.com/watch?v=#{id}"

  defp context(ts),
    do: %{timestamp_id: ts.id, reservation_id: ts.processing_context["work_reservation_id"]}

  defp set_config(values),
    do:
      Application.put_env(
        :drag_n_stamp,
        :work_budget,
        Keyword.merge(Application.get_env(:drag_n_stamp, :work_budget), values)
      )
end
