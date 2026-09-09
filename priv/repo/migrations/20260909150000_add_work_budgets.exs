defmodule DragNStamp.Repo.Migrations.AddWorkBudgets do
  use Ecto.Migration

  def change do
    create table(:work_budget_days, primary_key: false) do
      add :day, :date, primary_key: true
      add :reserved_microusd, :bigint, null: false, default: 0
      add :request_count, :integer, null: false, default: 0
      add :submission_count, :integer, null: false, default: 0
    end

    create table(:work_reservations) do
      add :timestamp_id, references(:timestamps, on_delete: :delete_all), null: false
      add :video_id, :string, null: false
      add :caller_hash, :string, null: false
      add :allowance_day, :date, null: false
      add :remaining_microusd, :bigint, null: false
      add :request_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:work_reservations, [:caller_hash, :inserted_at])
    create index(:work_reservations, [:video_id, :inserted_at])
    create index(:work_reservations, [:timestamp_id])
  end
end
