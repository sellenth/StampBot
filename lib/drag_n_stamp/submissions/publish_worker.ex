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
      keys: [:timestamp_id, :publication_source, :content_digest],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias DragNStamp.{Commenter, PublicationPolicy, Submissions, Timestamp}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(job), do: perform(job, [])

  @doc false
  def perform(%Oban.Job{args: %{"timestamp_id" => id} = args}, opts) do
    authority = PublicationPolicy.source(args["publication_source"])
    digest = args["content_digest"]

    with :ok <- PublicationPolicy.authorize(authority),
         true <- is_binary(digest) and byte_size(digest) == 64 do
      case Submissions.get(id) do
        %Timestamp{processing_status: :ready} = timestamp ->
          post_opts =
            [authority: authority, expected_digest: digest] ++ Keyword.take(opts, [:post_fun])

          case Commenter.post_for_timestamp(timestamp, post_opts) do
            {:ok, updated, {:error, reason}} ->
              Submissions.broadcast(updated)
              {:cancel, reason}

            {:ok, updated, _outcome} ->
              Submissions.broadcast(updated)
              :ok

            {:error, reason} ->
              {:cancel, reason}
          end

        _ ->
          {:cancel, :submission_not_ready}
      end
    else
      _ -> {:cancel, :publication_not_authorized}
    end
  end

  def perform(_job, _opts), do: {:cancel, :publication_not_authorized}
end
