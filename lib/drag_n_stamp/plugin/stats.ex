defmodule DragNStamp.Plugin.Stats do
  @moduledoc "Read-only aggregates for the plugin discovery experiment."
  import Ecto.Query
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Plugin.Usage.Event
  alias DragNStamp.Timestamps.CostEstimator

  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    hours = Keyword.get(opts, :hours, 168)
    cutoff = DateTime.add(now, -hours * 3_600, :second)
    events = from e in Event, where: e.inserted_at >= ^cutoff and e.inserted_at <= ^now

    accepted =
      from e in events,
        where: e.operation == "generate_chapters" and e.outcome in ["ready", "processing"]

    subjects = from e in accepted, where: e.identity_kind == "subject"

    returning =
      Repo.all(
        from e in subjects,
          group_by: e.actor_hash,
          having:
            count(e.session_hash, :distinct) > 1 or
              fragment("count(DISTINCT (? AT TIME ZONE 'UTC')::date) > 1", e.inserted_at),
          select: e.actor_hash
      )

    generated_ids =
      from e in events,
        where: e.new_work and not is_nil(e.timestamp_id),
        select: e.timestamp_id,
        distinct: true

    generated = from t in Timestamp, where: t.id in subquery(generated_ids)

    {known_cost, incomplete_cost} =
      Repo.one(
        from t in generated,
          select:
            {sum(t.estimated_cost_usd),
             filter(
               count(t.id),
               is_nil(t.estimated_cost_usd) or
                 fragment(
                   "COALESCE(?->>'cost_complete', 'false') != 'true'",
                   t.processing_context
                 )
             )}
      )

    %{
      generated_at: now,
      window_hours: hours,
      generate_calls: count(from e in events, where: e.operation == "generate_chapters"),
      accepted_generate_calls: count(accepted),
      new_jobs: count(from e in events, where: e.new_work),
      cached_generate_calls:
        count(from e in accepted, where: e.outcome == "ready" and not e.new_work),
      status_checks: count(from e in events, where: e.operation == "get_chapters"),
      ready_deliveries: count(from e in events, where: e.outcome == "ready"),
      requesting_subjects: Repo.one(from e in subjects, select: count(e.actor_hash, :distinct)),
      returning_subjects: length(returning),
      accepted_calls_without_subject:
        count(from e in accepted, where: e.identity_kind != "subject"),
      current_generated_results:
        Repo.all(
          from t in generated,
            group_by: t.processing_status,
            order_by: t.processing_status,
            select: %{status: t.processing_status, count: count(t.id)}
        ),
      current_generated_result_cost_usd: CostEstimator.serialize(known_cost),
      results_with_incomplete_cost: incomplete_cost,
      outcomes:
        Repo.all(
          from e in events,
            group_by: [e.operation, e.outcome, e.reason],
            order_by: [e.operation, e.outcome, e.reason],
            select: %{
              operation: e.operation,
              outcome: e.outcome,
              reason: e.reason,
              count: count(e.id)
            }
        ),
      daily:
        Repo.all(
          from e in events,
            group_by: fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at),
            order_by: fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at),
            select: %{
              day: fragment("(? AT TIME ZONE 'UTC')::date", e.inserted_at),
              generate_calls: filter(count(e.id), e.operation == "generate_chapters"),
              new_jobs: filter(count(e.id), e.new_work),
              ready_deliveries: filter(count(e.id), e.outcome == "ready")
            }
        ),
      measurement_note:
        "Tool calls measure use, not directory impressions, recommendations, or installs. Subject/session hints are optional and unverified; subject counts are estimates. Returning subjects requested generation in more than one session or UTC day. Status checks do not count as new demand. Test calls are included.",
      cost_note:
        "Cost sums current estimates for distinct submissions admitted through the plugin in this window. Cached results are excluded. Shared retries and incomplete provider usage prevent exact incremental billing attribution."
    }
  end

  defp count(query), do: Repo.aggregate(query, :count)
end
