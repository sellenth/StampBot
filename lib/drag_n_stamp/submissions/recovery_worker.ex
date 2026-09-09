defmodule DragNStamp.Submissions.RecoveryWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(_job), do: DragNStamp.Submissions.recover()
end
