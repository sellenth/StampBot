defmodule DragNStamp.BudgetReconciliationTest do
  use DragNStamp.DataCase, async: false
  alias DragNStamp.{ProcessingAttempt, ProcessingAttempts, Submissions, WorkBudget}
  alias DragNStamp.WorkBudget.{Day, Reservation}
  alias DragNStamp.Submissions.Processor
  alias DragNStamp.Timestamps.GeminiClient

  setup do
    previous = Application.get_env(:drag_n_stamp, :work_budget)
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true, caller_hourly_limit: 100)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :work_budget, previous) end)
    :ok
  end

  test "known usage replaces the request reserve and unused admission credit is released once" do
    ts = submit()
    request = claim(ts, :text)
    handle = %{id: request.id}

    cost =
      ProcessingAttempts.response(handle, %{model: "gemini-3.5-flash-lite"}, %{
        prompt_tokens: 1000,
        output_tokens: 100
      })

    assert %Decimal{} = cost
    micros = cost |> Decimal.mult(1_000_000) |> Decimal.round(0, :ceiling) |> Decimal.to_integer()
    assert micros < 500_000
    assert day().reserved_microusd == 1_000_000 + micros
    assert day().spent_microusd == micros
    assert :ok = WorkBudget.reconcile_request(request.id)
    assert :ok = WorkBudget.release_reservation(reservation_id(ts))
    assert :ok = WorkBudget.release_reservation(reservation_id(ts))
    assert day().reserved_microusd == micros
    assert day().spent_microusd == micros

    # Removing the user-facing result must not erase billed work.
    Repo.delete!(Repo.get!(DragNStamp.Timestamp, ts.id))
    assert WorkBudget.total_reserved_microusd() == micros
  end

  test "unknown and in-flight costs retain full request reserves after the run ends" do
    ts = submit()
    request = claim(ts, :text)
    assert request.dispatched
    assert :ok = WorkBudget.reconcile_request(request.id)
    assert :ok = WorkBudget.release_reservation(reservation_id(ts))
    assert day().reserved_microusd == 500_000
    assert day().spent_microusd == 0
    assert Repo.get!(ProcessingAttempt, request.id).budget_settled_microusd == nil
  end

  test "actual cost above the reserve is charged in full and stops subsequent dispatch" do
    ts = submit()
    request = claim(ts, :video)
    settle(request, "2.75")
    assert day().reserved_microusd == 2_750_000
    assert day().spent_microusd == 2_750_000
    put_config(total_budget_microusd: 2_000_000)
    next = attempt(ts, :text)

    assert {:error, :total_budget_exceeded} =
             WorkBudget.before_request(context(ts, :text), next.id)

    refute Repo.get!(ProcessingAttempt, next.id).dispatched
    assert day().request_count == 1
  end

  test "a request cannot claim twice or use another submission's reservation" do
    ts = submit()
    other = submit()
    request = claim(ts, :text)

    assert {:error, :work_budget_exceeded} =
             WorkBudget.before_request(context(ts, :text), request.id)

    assert {:error, :work_budget_exceeded} =
             WorkBudget.before_request(context(other, :text), request.id)

    assert day().request_count == 1
  end

  test "usage saved before a crash is reconciled before the next admission" do
    ts = submit()
    request = claim(ts, :video)

    ProcessingAttempts.annotate(%{id: request.id}, %{
      cost_status: :estimated,
      estimated_cost_usd: Decimal.new("0.01")
    })

    put_config(total_budget_microusd: 1_510_000)
    submit()
    assert day().reserved_microusd == 1_510_000
    assert day().spent_microusd == 10_000
  end

  test "late settlement refunds the original UTC day without reducing today's charges" do
    ts = submit()
    request = claim(ts, :video)
    yesterday = Date.add(Date.utc_today(), -1)
    Repo.update_all(Day, set: [day: yesterday])
    Repo.update_all(Reservation, set: [allowance_day: yesterday])
    Repo.update_all(ProcessingAttempt, set: [budget_day: yesterday])
    submit()
    settle(request, "0.000000001")
    assert Repo.get!(Day, yesterday).reserved_microusd == 1
    assert Repo.get!(Day, yesterday).spent_microusd == 1
    assert day().reserved_microusd == 1_500_000
  end

  test "processing that fails before any provider call releases its full admission hold" do
    ts = submit()
    assert {:error, %{reason: :missing_api_key}} = Processor.process(ts, api_key: nil)
    assert day().reserved_microusd == 0
    assert day().request_count == 0
  end

  test "abandoned admission holds are recovered but their unknown requests stay reserved" do
    ts = submit()
    claim(ts, :text)
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    submit()
    assert day().reserved_microusd == 2_000_000
    assert Repo.get!(Reservation, reservation_id(ts)).remaining_microusd == 0
  end

  test "rejected model output and retries settle usage while retaining request-count limits" do
    ts = submit()
    put_config(total_budget_microusd: 1_500_000, run_request_limit: 2)
    calls = :counters.new(1, [])

    result =
      ProcessingAttempts.with_context(context(ts, :text), fn ->
        GeminiClient.text_only_detailed("Fixture", "fixture-key",
          max_attempts: 3,
          sleep_fun: fn _ -> :ok end,
          request_fun: fn _, _ ->
            :counters.add(calls, 1, 1)

            {:ok,
             %Finch.Response{
               status: 200,
               headers: [],
               body:
                 Jason.encode!(%{
                   "candidates" => [
                     %{
                       "content" => %{"parts" => [%{"text" => "invalid"}]},
                       "finishReason" => "STOP"
                     }
                   ],
                   "usageMetadata" => %{"promptTokenCount" => 100, "candidatesTokenCount" => 20}
                 })
             }}
          end
        )
      end)

    assert {:error, %{kind: :work_budget_exceeded}} = result
    assert :counters.get(calls, 1) == 2
    WorkBudget.release_reservation(reservation_id(ts))
    assert day().reserved_microusd == day().spent_microusd
    assert day().spent_microusd > 0 and day().spent_microusd < 1_000
    assert day().request_count == 2
  end

  test "legacy migration settles known costs, retains unknowns and audit totals, and is idempotent" do
    ts = submit()
    a = attempt(ts, :video)
    b = attempt(ts, :text)
    c = attempt(ts, :text)

    for {request, cost} <- [{a, "0.025"}, {b, "0.000000001"}] do
      ProcessingAttempts.annotate(%{id: request.id}, %{
        dispatched: true,
        cost_status: :estimated,
        estimated_cost_usd: Decimal.new(cost)
      })
    end

    ProcessingAttempts.annotate(%{id: c.id}, %{dispatched: true})
    Repo.update_all(Day, set: [reserved_microusd: 3_500_000, request_count: 3])
    Repo.update_all(Reservation, set: [remaining_microusd: 1_000_000, request_count: 3])
    Submissions.update!(ts, %{processing_status: :ready, content: "0:00 Ready"})

    for _ <- 1..2 do
      backfill()

      assert day().reserved_microusd == 525_001
      assert day().spent_microusd == 25_001

      assert %{rows: [[3_500_000]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT legacy_reserved_microusd FROM work_budget_days WHERE day = $1",
                 [Date.utc_today()]
               )
    end

    assert Repo.get!(ProcessingAttempt, c.id).budget_reserved_microusd == 500_000
    assert Repo.get!(ProcessingAttempt, c.id).budget_settled_microusd == nil
  end

  test "legacy days with missing request history keep their conservative charges" do
    ts = submit()
    request = attempt(ts, :video)

    ProcessingAttempts.annotate(%{id: request.id}, %{
      dispatched: true,
      cost_status: :estimated,
      estimated_cost_usd: Decimal.new("0.01")
    })

    Repo.update_all(Day, set: [reserved_microusd: 3_000_000, request_count: 2])
    Repo.update_all(Reservation, set: [remaining_microusd: 0])
    backfill()
    assert day().reserved_microusd == 3_000_000
    assert day().spent_microusd == 0
    assert Repo.get!(ProcessingAttempt, request.id).budget_reserved_microusd == nil
  end

  defp backfill do
    module = DragNStamp.Repo.Migrations.ReconcileWorkBudgets

    Code.ensure_loaded?(module) ||
      Code.require_file(
        "../../priv/repo/migrations/20260925220000_reconcile_work_budgets.exs",
        __DIR__
      )

    for sql <- apply(module, :backfill_sql, [1_500_000, 500_000]),
        do: Ecto.Adapters.SQL.query!(Repo, sql, [])
  end

  defp submit do
    video =
      :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false) |> String.slice(0, 11)

    {:ok, ts, :created} = Submissions.submit("https://youtu.be/#{video}")
    ts
  end

  defp reservation_id(ts), do: ts.processing_context["work_reservation_id"]

  defp context(ts, operation),
    do: %{
      timestamp_id: ts.id,
      reservation_id: reservation_id(ts),
      operation: operation,
      run_id: Ecto.UUID.generate()
    }

  defp day, do: Repo.get!(Day, Date.utc_today())

  defp attempt(ts, operation) do
    %ProcessingAttempt{}
    |> ProcessingAttempt.changeset(%{
      timestamp_id: ts.id,
      reservation_id: reservation_id(ts),
      run_id: Ecto.UUID.generate(),
      kind: :request,
      stage: "video",
      operation: to_string(operation),
      status: :running,
      started_at: DateTime.utc_now(),
      cost_status: :unknown
    })
    |> Repo.insert!()
  end

  defp claim(ts, operation) do
    request = attempt(ts, operation)
    :ok = WorkBudget.before_request(context(ts, operation), request.id)
    Repo.get!(ProcessingAttempt, request.id)
  end

  defp settle(request, cost) do
    ProcessingAttempts.annotate(%{id: request.id}, %{
      cost_status: :estimated,
      estimated_cost_usd: Decimal.new(cost)
    })

    WorkBudget.reconcile_request(request.id)
  end

  defp put_config(values),
    do:
      Application.put_env(
        :drag_n_stamp,
        :work_budget,
        Keyword.merge(Application.get_env(:drag_n_stamp, :work_budget), values)
      )
end
