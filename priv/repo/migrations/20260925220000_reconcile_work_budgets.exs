defmodule DragNStamp.Repo.Migrations.ReconcileWorkBudgets do
  use Ecto.Migration

  def up do
    alter table(:work_budget_days) do
      add :spent_microusd, :bigint, null: false, default: 0
      # Retain the original gross ledger for auditing this one-time correction.
      add :legacy_reserved_microusd, :bigint
    end

    alter table(:processing_attempts) do
      add :budget_day, :date
      add :budget_reserved_microusd, :bigint
      add :budget_settled_microusd, :bigint
    end

    create index(:processing_attempts, [:id],
             name: :processing_attempts_unsettled_budget_index,
             where: "budget_reserved_microusd IS NOT NULL AND budget_settled_microusd IS NULL"
           )

    flush()
    execute "SELECT pg_advisory_xact_lock(hashtextextended('stampbot-work-budget', 0))"

    video = allowance("STAMPBOT_VIDEO_REQUEST_MICROUSD", 1_500_000)
    text = allowance("STAMPBOT_TEXT_REQUEST_MICROUSD", 500_000)
    Enum.each(backfill_sql(video, text), &execute/1)
  end

  def down do
    raise "Budget reconciliation is irreversible; preserve settled charges and audit history"
  end

  # Kept as SQL so the migration never depends on future application schemas.
  # Only fully attributable legacy days are reconstructed. Deleted/missing
  # request history remains conservatively charged rather than guessed away.
  def backfill_sql(video, text) when is_integer(video) and is_integer(text) do
    [
      """
      UPDATE work_budget_days SET legacy_reserved_microusd = reserved_microusd
      WHERE legacy_reserved_microusd IS NULL
      """,
      """
      WITH requests AS (
        SELECT id, started_at::date AS day,
               CASE WHEN operation = 'video' THEN #{video} ELSE #{text} END AS allowance
        FROM processing_attempts
        WHERE kind = 'request' AND dispatched AND reservation_id IS NOT NULL
      ), eligible AS (
        SELECT d.day FROM work_budget_days d
        JOIN requests a ON a.day = d.day
        GROUP BY d.day
        HAVING count(*) = d.request_count AND
          sum(a.allowance) + COALESCE((SELECT sum(r.remaining_microusd)
            FROM work_reservations r WHERE r.allowance_day = d.day), 0)
          <= d.reserved_microusd
      )
      UPDATE processing_attempts a
      SET budget_day = r.day, budget_reserved_microusd = r.allowance
      FROM requests r JOIN eligible e ON e.day = r.day
      WHERE a.id = r.id AND a.budget_reserved_microusd IS NULL
      """,
      """
      WITH settled AS (
        UPDATE processing_attempts
        SET budget_settled_microusd = CEIL(estimated_cost_usd * 1000000)::bigint
        WHERE budget_reserved_microusd IS NOT NULL AND budget_settled_microusd IS NULL
          AND cost_status = 'estimated' AND estimated_cost_usd IS NOT NULL
        RETURNING budget_day, budget_reserved_microusd, budget_settled_microusd
      ), totals AS (
        SELECT budget_day, sum(budget_settled_microusd) AS spent,
          sum(budget_settled_microusd - budget_reserved_microusd) AS adjustment
        FROM settled GROUP BY budget_day
      )
      UPDATE work_budget_days d
      SET reserved_microusd = d.reserved_microusd + t.adjustment,
          spent_microusd = d.spent_microusd + t.spent
      FROM totals t WHERE d.day = t.budget_day
      """,
      """
      WITH unused AS (
        SELECT r.id, r.allowance_day, r.remaining_microusd
        FROM work_reservations r JOIN timestamps t ON t.id = r.timestamp_id
        WHERE r.remaining_microusd > 0 AND
          (r.allowance_day < (now() AT TIME ZONE 'UTC')::date OR t.processing_status <> 'processing'
            OR NOT EXISTS (SELECT 1 FROM oban_jobs j
              WHERE j.worker = 'DragNStamp.Submissions.Worker'
                AND j.args->>'timestamp_id' = r.timestamp_id::text
                AND j.state IN ('available', 'scheduled', 'executing', 'retryable')))
      ), released AS (
        UPDATE work_reservations r SET remaining_microusd = 0 FROM unused u
        WHERE r.id = u.id RETURNING u.allowance_day, u.remaining_microusd
      ), totals AS (
        SELECT allowance_day, sum(remaining_microusd) AS amount
        FROM released GROUP BY allowance_day
      )
      UPDATE work_budget_days d SET reserved_microusd = d.reserved_microusd - t.amount
      FROM totals t WHERE d.day = t.allowance_day
      """
    ]
  end

  defp allowance(name, default) do
    case Integer.parse(System.get_env(name) || to_string(default)) do
      {value, ""} when value > 0 -> value
      _ -> raise "Invalid allowance: #{name}"
    end
  end
end
