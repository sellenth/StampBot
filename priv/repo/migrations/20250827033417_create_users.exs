defmodule DragNStamp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :picture, :string
      add :provider, :string, null: false
      add :uid, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:provider, :uid])
    create index(:users, [:email])
  end
end
