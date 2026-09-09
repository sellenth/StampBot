defmodule DragNStamp.SubmissionsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias DragNStamp.{ProcessingAttempts, Repo, Submissions, Timestamp}
  alias DragNStamp.Submissions.Worker
  alias DragNStamp.Timestamps.GeminiClient
  alias DragNStamp.Timestamps.GeminiClient.Result

  @generated "0:00 Opening evidence introduces the subject and planned demonstration\n" <>
               "2:00 Final evidence explains the outcome and remaining practical lessons"

  test "simultaneous canonical variants create one record and job across independent transactions" do
    [video_id] = fixture_video_ids(1)

    urls = [
      "https://www.youtube.com/watch?v=#{video_id}&list=example&t=30",
      "https://youtu.be/#{video_id}?si=example",
      "https://www.youtube.com/shorts/#{video_id}",
      "https://www.youtube.com/embed/#{video_id}"
    ]

    # Limit participants to actual pool capacity so the barrier also works on
    # small CI machines. Each participant holds a different checked-out backend.
    urls = Enum.take(urls, min(4, Repo.config()[:pool_size]))
    assert length(urls) >= 2

    results = submit_together(urls)

    submitted =
      Enum.map(results, fn result ->
        assert {:ok, {:ok, timestamp, disposition}} = result
        {timestamp, disposition}
      end)

    ids = Enum.map(submitted, fn {timestamp, _} -> timestamp.id end)
    assert length(Enum.uniq(ids)) == 1
    assert Enum.count(submitted, fn {_, disposition} -> disposition == :created end) == 1

    unboxed(fn ->
      assert Repo.aggregate(from(t in Timestamp, where: t.video_id == ^video_id), :count) == 1
      assert [%Oban.Job{state: "available", queue: "submissions"}] = jobs_for(ids)
    end)
  end

  test "different videos submitted simultaneously both retain independently queued jobs" do
    video_ids = fixture_video_ids(2)
    results = submit_together(Enum.map(video_ids, &video_url/1))

    timestamps =
      Enum.map(results, fn result ->
        assert {:ok, {:ok, timestamp, :created}} = result
        timestamp
      end)

    ids = Enum.map(timestamps, & &1.id)
    assert length(Enum.uniq(ids)) == 2

    unboxed(fn ->
      assert Repo.aggregate(from(t in Timestamp, where: t.id in ^ids), :count) == 2
      jobs = jobs_for(ids)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.state == "available" and &1.queue == "submissions"))
      assert Enum.sort(Enum.map(jobs, & &1.args["timestamp_id"])) == Enum.sort(ids)
    end)
  end

  test "a killed worker leaves a committed checkpoint that resumes after orphan rescue and restart" do
    [video_id] = fixture_video_ids(1)
    queue = "checkpoint_restart_#{video_id}"
    oban_name = {__MODULE__, make_ref()}

    oban_opts = [
      name: oban_name,
      repo: Repo,
      testing: :manual,
      notifier: Oban.Notifiers.Isolated
    ]

    start_supervised!({Oban, oban_opts})

    {timestamp_id, job_id} =
      unboxed(fn ->
        {:ok, timestamp, :created} = Submissions.submit(video_url(video_id))
        Submissions.update!(timestamp, %{video_duration_seconds: 180})
        [job] = jobs_for([timestamp.id])

        # This queue is private to the isolated instance. Other committed jobs
        # can never be drained by the crash/restart scenario.
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [queue: queue])
        {timestamp.id, job.id}
      end)

    parent = self()
    calls = :counters.new(2, [])
    previous_opts = Application.get_env(:drag_n_stamp, :submission_processor_options)

    on_exit(fn ->
      if is_nil(previous_opts) do
        Application.delete_env(:drag_n_stamp, :submission_processor_options)
      else
        Application.put_env(:drag_n_stamp, :submission_processor_options, previous_opts)
      end
    end)

    Application.put_env(:drag_n_stamp, :submission_processor_options,
      api_key: "offline-fixture-key",
      publish: false,
      metadata_fun: fn timestamp -> {:ok, timestamp} end,
      video_fun: fn _, _, _, _ ->
        :counters.add(calls, 1, 1)
        {:ok, model_result()}
      end,
      caption_fun: fn _, _, _, _ -> flunk("The video fixture does not need captions") end,
      text_fun: fn prompt, key, opts ->
        :counters.add(calls, 2, 1)

        GeminiClient.text_only_detailed(
          prompt,
          key,
          Keyword.put(opts, :request_fun, fn _, _ ->
            send(parent, {:distillation_blocked, self()})

            receive do
              :unexpected_continue -> flunk("The first executor must be killed before returning")
            end
          end)
        )
      end
    )

    {executor, monitor} =
      spawn_monitor(fn ->
        unboxed(fn -> Oban.drain_queue(oban_name, queue: queue, with_limit: 1) end)
      end)

    try do
      assert_receive {:distillation_blocked, ^executor}, 5_000

      unboxed(fn ->
        checkpoint = Repo.get!(Timestamp, timestamp_id)
        assert checkpoint.content == @generated
        assert checkpoint.processing_phase == "distilling"
        assert checkpoint.processing_status == :processing
        assert checkpoint.processing_context["output_bound_seconds"] == 180
        assert Repo.get!(Oban.Job, job_id).state == "executing"

        assert [request] =
                 ProcessingAttempts.for_timestamp(timestamp_id)
                 |> Enum.filter(&(&1.kind == :request))

        assert request.dispatched
        assert request.status == :running
        assert request.cost_status == :unknown
      end)

      # :kill is untrappable: neither Worker rescue nor Oban acknowledgement can
      # convert it into an ordinary returned failure or complete the job.
      Process.exit(executor, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 5_000

      stop_supervised!(oban_name)
      start_supervised!({Oban, oban_opts})

      unboxed(fn ->
        orphan = Repo.get!(Oban.Job, job_id)
        assert orphan.state == "executing"
        assert orphan.attempt == 1

        # Advance this job's age instead of waiting 35 minutes. Invoke the same
        # engine operation as Oban.Lifeline, scoped to this fixture's exact job.
        old_attempt = DateTime.add(DateTime.utc_now(), -36 * 60, :second)

        Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id),
          set: [attempted_at: old_attempt]
        )

        assert {:ok, [%{id: ^job_id, state: "available"}]} =
                 Oban.Engine.rescue_jobs(
                   Oban.config(oban_name),
                   from(j in Oban.Job, where: j.id == ^job_id),
                   rescue_after: :timer.minutes(35)
                 )
      end)

      Application.put_env(:drag_n_stamp, :submission_processor_options,
        api_key: "offline-fixture-key",
        publish: false,
        metadata_fun: fn _ -> flunk("Restart must reuse the saved checkpoint") end,
        video_fun: fn _, _, _, _ -> flunk("Restart must not repeat video generation") end,
        caption_fun: fn _, _, _, _ -> flunk("Restart must not reacquire captions") end,
        text_fun: fn prompt, key, opts ->
          :counters.add(calls, 2, 1)
          assert opts[:max_seconds] == 180

          GeminiClient.text_only_detailed(
            prompt,
            key,
            Keyword.put(opts, :request_fun, fn _, _ -> provider_response() end)
          )
        end
      )

      unboxed(fn ->
        assert %{success: 1, failure: 0} =
                 Oban.drain_queue(oban_name, queue: queue, with_limit: 1)

        ready = Repo.get!(Timestamp, timestamp_id)
        assert ready.processing_status == :ready
        assert ready.distilled_content =~ @generated
        assert [%Oban.Job{state: "completed", attempt: 2}] = jobs_for([timestamp_id])

        attempts = ProcessingAttempts.for_timestamp(timestamp_id)
        assert Enum.all?(attempts, &(&1.status != :running))
        assert [interrupted, resumed] = Enum.filter(attempts, &(&1.kind == :request))
        assert interrupted.job_id == job_id
        assert interrupted.job_attempt == 1
        assert interrupted.status == :interrupted
        assert interrupted.failure_kind == "worker_interrupted"
        assert interrupted.duration_ms == nil
        assert interrupted.cost_status == :unknown
        assert interrupted.estimated_cost_usd == nil
        assert resumed.job_attempt == 2
        assert resumed.status == :succeeded
        assert resumed.cost_status == :estimated
        assert ready.processing_context["model_request_count"] == 2
        assert ready.processing_context["unknown_cost_requests"] == 1
        refute ready.processing_context["cost_complete"]
      end)

      assert :counters.get(calls, 1) == 1
      assert :counters.get(calls, 2) == 2
    after
      if Process.alive?(executor), do: Process.exit(executor, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp submit_together(urls) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(urls, fn url ->
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              %{rows: [[backend_pid, transaction_id]]} =
                Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid(), txid_current()", [])

              send(parent, {:transaction_ready, barrier, self(), backend_pid, transaction_id})

              receive do
                {:submit, ^barrier} -> Submissions.submit(url)
              after
                10_000 -> raise "Concurrent submission barrier was never released"
              end
            end)
          end)
        end)
      end)

    try do
      connections =
        Enum.map(tasks, fn task ->
          pid = task.pid
          assert_receive {:transaction_ready, ^barrier, ^pid, backend_pid, transaction_id}, 5_000
          {backend_pid, transaction_id}
        end)

      assert length(Enum.uniq_by(connections, &elem(&1, 0))) == length(tasks)
      assert length(Enum.uniq_by(connections, &elem(&1, 1))) == length(tasks)

      Enum.each(tasks, &send(&1.pid, {:submit, barrier}))
      Task.await_many(tasks, 10_000)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp fixture_video_ids(count) do
    video_ids =
      for _ <- 1..count,
          do:
            :crypto.strong_rand_bytes(9)
            |> Base.url_encode64(padding: false)
            |> String.slice(0, 11)

    unboxed(fn ->
      assert Repo.aggregate(from(t in Timestamp, where: t.video_id in ^video_ids), :count) == 0
    end)

    # These tests deliberately commit outside the sandbox. Cleanup is restricted
    # to fresh random fixture identities and jobs referencing those exact rows.
    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          ids = Repo.all(from(t in Timestamp, where: t.video_id in ^video_ids, select: t.id))
          string_ids = Enum.map(ids, &to_string/1)

          Repo.delete_all(
            from(j in Oban.Job, where: fragment("?->>'timestamp_id'", j.args) in ^string_ids)
          )

          Repo.delete_all(from(t in Timestamp, where: t.id in ^ids))
        end)
      end)
    end)

    video_ids
  end

  defp jobs_for(ids) do
    worker = Oban.Worker.to_string(Worker)
    string_ids = Enum.map(ids, &to_string/1)

    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker and fragment("?->>'timestamp_id'", j.args) in ^string_ids,
        order_by: j.id
      )
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
  defp video_url(video_id), do: "https://www.youtube.com/watch?v=#{video_id}"

  defp model_result do
    %Result{
      content: @generated,
      timestamps: [
        %{seconds: 0, title: "Opening evidence introduces the subject and planned demonstration"},
        %{
          seconds: 120,
          title: "Final evidence explains the outcome and remaining practical lessons"
        }
      ],
      model: "offline-fixture",
      duration_ms: 1,
      attempts: 1
    }
  end

  defp provider_response do
    {:ok,
     %Finch.Response{
       status: 200,
       headers: [],
       body:
         Jason.encode!(%{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [%{"text" => Jason.encode!(%{timestamps: model_result().timestamps})}]
               },
               "finishReason" => "STOP"
             }
           ],
           "usageMetadata" => %{"promptTokenCount" => 100, "candidatesTokenCount" => 20}
         })
     }}
  end
end
