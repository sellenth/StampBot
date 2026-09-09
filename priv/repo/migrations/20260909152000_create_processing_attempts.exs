defmodule DragNStamp.Repo.Migrations.CreateProcessingAttempts do
  use Ecto.Migration

  def change do
    create table(:processing_attempts) do
      add :timestamp_id, references(:timestamps, on_delete: :delete_all), null: false
      add :parent_attempt_id, references(:processing_attempts, on_delete: :nilify_all)
      # Keep job linkage after Oban's retention policy prunes the original job.
      add :job_id, :bigint
      add :job_attempt, :integer
      add :reservation_id, :bigint
      add :run_id, :uuid, null: false
      add :kind, :string, null: false
      add :stage, :string, null: false
      add :status, :string, null: false, default: "running"
      add :provider, :string
      add :operation, :string
      add :chunk_index, :integer
      add :request_attempt, :integer
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :failure_kind, :string
      add :http_status, :integer
      add :dispatched, :boolean, null: false, default: false
      add :model, :string
      add :model_version, :string
      add :thinking_level, :string
      add :prompt_version, :string
      add :schema_version, :string
      add :provider_request_id, :string
      add :finish_reason, :string
      add :input_bytes, :bigint
      add :start_seconds, :integer
      add :end_seconds, :integer
      add :prompt_tokens, :bigint
      add :output_tokens, :bigint
      add :thinking_tokens, :bigint
      add :cached_tokens, :bigint
      add :total_tokens, :bigint
      add :usage_status, :string, null: false, default: "not_reported"
      add :cost_status, :string, null: false, default: "not_applicable"
      add :estimated_cost_usd, :decimal, precision: 18, scale: 9
      timestamps(type: :utc_datetime_usec)
    end

    create index(:processing_attempts, [:timestamp_id, :id])
    create index(:processing_attempts, [:job_id, :job_attempt])
    create index(:processing_attempts, [:run_id])
    create index(:processing_attempts, [:started_at, :kind, :status])
    create index(:processing_attempts, [:status], where: "status = 'running'")
  end
end
