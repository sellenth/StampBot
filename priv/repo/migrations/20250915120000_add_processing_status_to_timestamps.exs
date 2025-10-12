defmodule DragNStamp.Repo.Migrations.AddProcessingStatusToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :processing_status, :string, null: false, default: "processing"
      add :processing_error, :text
    end

    execute(
      "UPDATE timestamps SET processing_status = 'ready'",
      "UPDATE timestamps SET processing_status = 'processing'"
    )
  end
end
