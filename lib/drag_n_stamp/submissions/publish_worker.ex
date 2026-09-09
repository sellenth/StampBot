defmodule DragNStamp.Submissions.PublishWorker do
  @moduledoc "Publishes completed results separately from generation."
  # YouTube does not offer a request idempotency key. An interrupted HTTP post
  # has an uncertain outcome, so never automatically repeat a publishing job.
  use Oban.Worker,
    queue: :publishing,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:timestamp_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias DragNStamp.{Commenter, Submissions, Timestamp}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"timestamp_id" => id}}) do
    case Submissions.get(id) do
      %Timestamp{processing_status: :ready} = timestamp ->
        case Commenter.post_for_timestamp(timestamp) do
          {:ok, updated, _outcome} ->
            Submissions.broadcast(updated)
            :ok

          {:error, reason} ->
            {:cancel, reason}
        end

      _ ->
        {:cancel, :submission_not_ready}
    end
  end
end
