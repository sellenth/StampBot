defmodule DragNStamp.Timestamps.SubmissionLimit do
  @moduledoc """
  Enforces the lifetime cap on newly created timestamp records.

  The PostgreSQL advisory transaction lock keeps simultaneous requests on
  separate application instances from creating records past the cap.
  """

  alias DragNStamp.{Repo, Timestamp}

  @limit 1_000
  @advisory_lock_key 73_684_576_649_001
  @message "Congrats on 1k. We are all out of funds. Please contact Halston Sellentin if you would like to support our mission!"

  def limit, do: @limit
  def message, do: @message

  def reached? do
    Repo.aggregate(Timestamp, :count, :id) >= @limit
  end

  def insert_if_available(%Ecto.Changeset{} = changeset) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock($1)",
        [@advisory_lock_key]
      )

      if reached?() do
        Repo.rollback(:submission_limit_reached)
      end

      case Repo.insert(changeset) do
        {:ok, timestamp} -> timestamp
        {:error, failed_changeset} -> Repo.rollback(failed_changeset)
      end
    end)
    |> case do
      {:ok, timestamp} -> {:ok, timestamp}
      {:error, reason} -> {:error, reason}
    end
  end
end
