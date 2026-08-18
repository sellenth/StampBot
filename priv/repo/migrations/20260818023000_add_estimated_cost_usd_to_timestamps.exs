defmodule DragNStamp.Repo.Migrations.AddEstimatedCostUsdToTimestamps do
  use Ecto.Migration

  def change do
    alter table(:timestamps) do
      add :estimated_cost_usd, :decimal, precision: 14, scale: 8
    end
  end
end
