defmodule DragNStamp.Repo.Migrations.AddProcessingContextToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :processing_context, :map
    end
  end
end

