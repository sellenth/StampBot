defmodule DragNStamp.Submissions.Worker do
  @moduledoc "Bounded, resumable execution of a persisted submission."
  use Oban.Worker,
    queue: :submissions,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:timestamp_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger
  import Ecto.Query
  alias DragNStamp.{Repo, Submissions, Timestamp}
  alias DragNStamp.Submissions.Processor

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"timestamp_id" => id}} = job) do
    case Submissions.get(id) do
      nil -> {:cancel, :submission_deleted}
      %Timestamp{processing_status: :ready} -> :ok
      timestamp -> run(timestamp, job)
    end
  rescue
    error ->
      Logger.error("Submission job #{job.id} crashed exception_type=#{inspect(error.__struct__)}")

      failed(job, %{
        reason: :worker_exception,
        message: "A processing service failed unexpectedly.",
        retryable: true
      })
  end

  defp run(timestamp, job) do
    context = (timestamp.processing_context || %{}) |> Map.put("attempt", job.attempt)
    timestamp = Submissions.update!(timestamp, %{processing_context: context})

    opts =
      Application.get_env(:drag_n_stamp, :submission_processor_options, [])
      |> Keyword.put(:job_id, job.id)
      |> Keyword.put(:job_attempt, job.attempt)

    case Processor.process(timestamp, opts) do
      {:ok, _updated} -> :ok
      {:error, failure} -> failed(job, failure)
    end
  end

  defp failed(job, failure) do
    retry? = failure.retryable and job.attempt < job.max_attempts

    {:ok, result} =
      Repo.transaction(fn ->
        timestamp =
          Repo.one(
            from(t in Timestamp,
              where: t.id == ^job.args["timestamp_id"],
              lock: "FOR UPDATE"
            )
          )

        case timestamp do
          %Timestamp{processing_status: :ready} ->
            :ready

          nil ->
            nil

          timestamp ->
            context =
              (timestamp.processing_context || %{})
              |> Map.put("public_error", failure.message)
              |> Map.put("last_failure", to_string(failure.reason))

            timestamp
            |> Timestamp.changeset(%{
              processing_status: if(retry?, do: :processing, else: :failed),
              processing_phase: if(retry?, do: "retrying", else: "failed"),
              processing_error: failure.message,
              processing_context: context
            })
            |> Repo.update!()
        end
      end)

    case result do
      :ready ->
        :ok

      timestamp ->
        if timestamp, do: Submissions.broadcast(timestamp)
        if retry?, do: {:error, failure.reason}, else: {:cancel, failure.reason}
    end
  end
end
