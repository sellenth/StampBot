defmodule DragNStamp.WorkBudgetConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox

  alias DragNStamp.{
    ProcessingAttempt,
    ProcessingAttempts,
    Repo,
    Submissions,
    Timestamp,
    WorkBudget
  }

  alias DragNStamp.WorkBudget.{Day, Reservation}

  for {budget_key, exhausted_reason} <- [
        {:daily_budget_microusd, :daily_budget_exceeded},
        {:total_budget_microusd, :total_budget_exceeded}
      ] do
    test "independent transactions cannot reserve the same final #{budget_key} allowance" do
      original_config = Application.get_env(:drag_n_stamp, :work_budget)
      day = Date.utc_today()
      original_day = unboxed(fn -> Repo.get(Day, day) end)
      original_reserved = if original_day, do: original_day.reserved_microusd, else: 0
      original_count = if original_day, do: original_day.submission_count, else: 0

      videos =
        for _ <- 1..2,
            do:
              :crypto.strong_rand_bytes(9)
              |> Base.url_encode64(padding: false)
              |> String.slice(0, 11)

      original_total = unboxed(fn -> WorkBudget.total_reserved_microusd() end)

      used =
        if unquote(budget_key) == :daily_budget_microusd,
          do: original_reserved,
          else: original_total

      config = [
        enabled: true,
        caller_hourly_limit: 1000,
        daily_submission_limit: original_count + 10,
        daily_budget_microusd: original_reserved + 10_000_000,
        total_budget_microusd: original_total + 10_000_000
      ]

      Application.put_env(
        :drag_n_stamp,
        :work_budget,
        Keyword.put(config, unquote(budget_key), used + 1_500_000)
      )

      on_exit(fn ->
        Application.put_env(:drag_n_stamp, :work_budget, original_config)

        unboxed(fn ->
          Repo.transaction(fn ->
            ids = Repo.all(from t in Timestamp, where: t.video_id in ^videos, select: t.id)
            string_ids = Enum.map(ids, &to_string/1)

            Repo.delete_all(
              from j in Oban.Job, where: fragment("?->>'timestamp_id'", j.args) in ^string_ids
            )

            Repo.delete_all(from r in Reservation, where: r.timestamp_id in ^ids)
            Repo.delete_all(from t in Timestamp, where: t.id in ^ids)
            # Restore only the exact budget row changed by this non-async fixture.
            if original_day do
              Repo.update_all(from(d in Day, where: d.day == ^day),
                set: [
                  reserved_microusd: original_day.reserved_microusd,
                  request_count: original_day.request_count,
                  submission_count: original_day.submission_count
                ]
              )
            else
              Repo.delete_all(from d in Day, where: d.day == ^day)
            end
          end)
        end)
      end)

      parent = self()
      barrier = make_ref()

      tasks =
        Enum.map(videos, fn video ->
          Task.async(fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                %{rows: [[pid, txid]]} =
                  Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid(), txid_current()", [])

                send(parent, {:ready, barrier, self(), pid, txid})

                receive do
                  {:go, ^barrier} ->
                    outcome =
                      Submissions.submit("https://youtu.be/#{video}", %{}, caller_hash: video)

                    send(parent, {:outcome, barrier, outcome})
                    outcome
                after
                  5000 -> raise "barrier timeout"
                end
              end)
            end)
          end)
        end)

      try do
        connections =
          Enum.map(tasks, fn task ->
            pid = task.pid
            assert_receive {:ready, ^barrier, ^pid, backend, txid}, 5000
            {backend, txid}
          end)

        assert length(Enum.uniq_by(connections, &elem(&1, 0))) == 2
        assert length(Enum.uniq_by(connections, &elem(&1, 1))) == 2
        Enum.each(tasks, &send(&1.pid, {:go, barrier}))
        results = Task.await_many(tasks, 10_000)
        assert Enum.count(results, &match?({:ok, {:ok, _, :created}}, &1)) == 1
        assert Enum.count(results, &match?({:error, :rollback}, &1)) == 1
        expected_reason = unquote(exhausted_reason)
        assert_receive {:outcome, ^barrier, {:error, ^expected_reason}}
        assert_receive {:outcome, ^barrier, {:ok, _, :created}}

        unboxed(fn ->
          assert Repo.aggregate(from(t in Timestamp, where: t.video_id in ^videos), :count) == 1
          budget = Repo.get!(Day, day)
          assert budget.reserved_microusd == original_reserved + 1_500_000
          assert budget.submission_count == original_count + 1
        end)
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      end
    end
  end

  test "independent settlements of one request cannot return its reserve twice" do
    previous_config = Application.get_env(:drag_n_stamp, :work_budget)
    today = Date.utc_today()
    original_day = unboxed(fn -> Repo.get(Day, today) end)

    video =
      :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false) |> String.slice(0, 11)

    Application.put_env(:drag_n_stamp, :work_budget,
      enabled: true,
      caller_hourly_limit: 1000,
      daily_budget_microusd: 1_000_000_000,
      total_budget_microusd: 1_000_000_000
    )

    on_exit(fn ->
      Application.put_env(:drag_n_stamp, :work_budget, previous_config)

      unboxed(fn ->
        ids = Repo.all(from t in Timestamp, where: t.video_id == ^video, select: t.id)
        strings = Enum.map(ids, &to_string/1)

        Repo.delete_all(
          from j in Oban.Job, where: fragment("?->>'timestamp_id'", j.args) in ^strings
        )

        Repo.delete_all(from t in Timestamp, where: t.id in ^ids)

        if original_day do
          Repo.update_all(from(d in Day, where: d.day == ^today),
            set: [
              reserved_microusd: original_day.reserved_microusd,
              spent_microusd: original_day.spent_microusd,
              request_count: original_day.request_count,
              submission_count: original_day.submission_count
            ]
          )
        else
          Repo.delete_all(from d in Day, where: d.day == ^today)
        end
      end)
    end)

    request =
      unboxed(fn ->
        {:ok, ts, :created} =
          Submissions.submit("https://youtu.be/#{video}", %{}, caller_hash: video)

        context = %{
          timestamp_id: ts.id,
          reservation_id: ts.processing_context["work_reservation_id"],
          operation: :video
        }

        request =
          %ProcessingAttempt{}
          |> ProcessingAttempt.changeset(%{
            timestamp_id: ts.id,
            reservation_id: context.reservation_id,
            run_id: Ecto.UUID.generate(),
            kind: :request,
            stage: "video",
            operation: "video",
            status: :running,
            started_at: DateTime.utc_now(),
            cost_status: :unknown
          })
          |> Repo.insert!()

        :ok = WorkBudget.before_request(context, request.id)

        ProcessingAttempts.annotate(%{id: request.id}, %{
          cost_status: :estimated,
          estimated_cost_usd: Decimal.new("0.01")
        })

        request
      end)

    parent = self()
    barrier = make_ref()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              %{rows: [[backend]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
              send(parent, {:settler_ready, barrier, self(), backend})

              receive do
                {:settle, ^barrier} -> WorkBudget.reconcile_request(request.id)
              after
                5000 -> raise "settlement barrier timeout"
              end
            end)
          end)
        end)
      end

    try do
      backends =
        for task <- tasks do
          pid = task.pid
          assert_receive {:settler_ready, ^barrier, ^pid, backend}, 5000
          backend
        end

      assert length(Enum.uniq(backends)) == 2
      Enum.each(tasks, &send(&1.pid, {:settle, barrier}))
      assert Task.await_many(tasks, 10_000) == [{:ok, :ok}, {:ok, :ok}]

      unboxed(fn ->
        day = Repo.get!(Day, today)

        assert day.reserved_microusd ==
                 if(original_day, do: original_day.reserved_microusd, else: 0) + 10_000

        assert day.spent_microusd ==
                 if(original_day, do: original_day.spent_microusd, else: 0) + 10_000
      end)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
