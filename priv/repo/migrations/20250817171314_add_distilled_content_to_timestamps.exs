defmodule DragNStamp.Repo.Migrations.AddDistilledContentToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :distilled_content, :text
    end
  end
end
