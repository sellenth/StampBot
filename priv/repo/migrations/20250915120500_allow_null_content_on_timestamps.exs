defmodule DragNStamp.Repo.Migrations.AllowNullContentOnTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      modify :content, :text, null: true
    end
  end
end
