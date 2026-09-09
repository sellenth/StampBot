defmodule DragNStamp.Operations do
  @moduledoc "Read-only operator summaries from durable attempts, queue state, and work allowances."
  import Ecto.Query
  alias DragNStamp.{ProcessingAttempt, Repo, Timestamp, WorkBudget}
  alias DragNStamp.Timestamps.CostEstimator
  alias DragNStamp.WorkBudget.Day

  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    hours = Keyword.get(opts, :hours, 24)
    cutoff = DateTime.add(now, -hours * 3_600, :second)
    attempts = from a in ProcessingAttempt, where: a.started_at >= ^cutoff
    requests = from a in attempts, where: a.kind == :request and a.dispatched

    {known_cost, request_count, unknown_count} =
      Repo.one(
        from a in requests,
          select:
            {sum(a.estimated_cost_usd), count(a.id),
             filter(count(a.id), a.cost_status == :unknown)}
      )

    stages =
      Repo.all(
        from a in attempts,
          where: a.kind in [:run, :stage, :chunk],
          group_by: [a.stage, a.status],
          order_by: [a.stage, a.status],
          select: %{
            stage: a.stage,
            status: a.status,
            count: count(a.id),
            mean_duration_ms: avg(a.duration_ms)
          }
      )
      |> Enum.map(
        &Map.update!(&1, :mean_duration_ms, fn value -> if value, do: Decimal.to_float(value) end)
      )

    request_outcomes =
      Repo.all(
        from a in requests,
          group_by: [a.operation, a.status, a.failure_kind],
          order_by: [a.operation, a.status],
          select: %{
            operation: a.operation,
            status: a.status,
            failure_kind: a.failure_kind,
            count: count(a.id)
          }
      )

    queues =
      Repo.all(
        from j in Oban.Job,
          where: j.state in ["available", "scheduled", "retryable", "executing"],
          group_by: [j.queue, j.state],
          order_by: [j.queue, j.state],
          select: %{
            queue: j.queue,
            state: j.state,
            count: count(j.id),
            oldest_inserted_at: min(j.inserted_at)
          }
      )
      |> Enum.map(
        &Map.put(&1, :oldest_age_seconds, max(DateTime.diff(now, &1.oldest_inserted_at), 0))
      )

    unfinished = Repo.aggregate(from(a in ProcessingAttempt, where: a.status == :running), :count)
    interrupted = Repo.aggregate(from(a in attempts, where: a.status == :interrupted), :count)

    orphaned =
      Repo.aggregate(
        from(a in ProcessingAttempt,
          left_join: j in Oban.Job,
          on: j.id == a.job_id,
          where:
            a.status == :running and not is_nil(a.job_id) and
              (is_nil(j.id) or j.state in ["completed", "cancelled", "discarded"] or
                 j.attempt > a.job_attempt)
        ),
        :count
      )

    pending_cutoff = DateTime.add(now, -120, :second)

    uncertain_query =
      from t in Timestamp,
        where:
          t.youtube_comment_status == :pending and
            (is_nil(t.youtube_comment_last_attempt_at) or
               t.youtube_comment_last_attempt_at <= ^pending_cutoff),
        order_by: [asc_nulls_first: t.youtube_comment_last_attempt_at],
        select: %{timestamp_id: t.id, last_attempt_at: t.youtube_comment_last_attempt_at}

    uncertain_count = Repo.aggregate(uncertain_query, :count)
    uncertain = Repo.all(from t in uncertain_query, limit: 25)

    %{
      generated_at: now,
      window_hours: hours,
      queues: queues,
      stage_outcomes: stages,
      request_outcomes: request_outcomes,
      request_count: request_count,
      known_estimated_cost_usd: CostEstimator.serialize(known_cost),
      unknown_cost_request_count: unknown_count,
      running_attempt_count: unfinished,
      orphaned_attempt_count: orphaned,
      interrupted_attempt_count: interrupted,
      uncertain_publishing_count: uncertain_count,
      uncertain_publishing: uncertain,
      work_allowances: work_allowances(now)
    }
  end

  defp work_allowances(now) do
    day = Repo.get(Day, DateTime.to_date(now))

    %{
      day: DateTime.to_date(now),
      enabled: WorkBudget.enabled?(),
      reserved_allowance_usd: usd(if(day, do: day.reserved_microusd, else: 0)),
      daily_allowance_limit_usd: usd(WorkBudget.config(:daily_budget_microusd)),
      requests_claimed: if(day, do: day.request_count, else: 0),
      daily_request_limit: WorkBudget.config(:daily_request_limit),
      submissions_reserved: if(day, do: day.submission_count, else: 0),
      daily_submission_limit: WorkBudget.config(:daily_submission_limit),
      video_request_allowance_usd: usd(WorkBudget.config(:video_request_microusd)),
      text_request_allowance_usd: usd(WorkBudget.config(:text_request_microusd)),
      accounting_note:
        "Allowances are conservative planning estimates, not a provider billing cap. Unknown outcomes are not refunded."
    }
  end

  defp usd(microusd),
    do:
      microusd
      |> Decimal.new()
      |> Decimal.div(Decimal.new(1_000_000))
      |> CostEstimator.serialize()
end
