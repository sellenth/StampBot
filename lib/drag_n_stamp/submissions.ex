defmodule DragNStamp.Submissions do
  @moduledoc "Accepts submissions atomically and exposes their durable processing state."

  import Ecto.Query

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Submissions.Worker
  alias DragNStamp.Timestamps.{CostEstimator, FailureMessage, SubmissionLimit}
  alias DragNStamp.YouTube.URL

  @active_states ~w(available scheduled executing retryable)

  def submit(url, attrs \\ %{}) do
    with {:ok, identity} <- URL.parse(url),
         {:ok, {timestamp, disposition}} <-
           Repo.transaction(fn ->
             lock_video(identity.video_id)

             case find_existing(identity) do
               nil ->
                 timestamp = insert_timestamp!(identity, attrs)
                 enqueue!(timestamp)
                 {timestamp, :created}

               %Timestamp{processing_status: :ready} = timestamp ->
                 {timestamp, :existing}

               %Timestamp{processing_status: :failed} = timestamp ->
                 # The worker persists failure before Oban acknowledges its
                 # cancellation. Do not reset a row then collide with that old
                 # executing job's unique key and silently lose the new run.
                 if active_job?(timestamp.id), do: Repo.rollback(:retry_in_flight)
                 timestamp = reset!(timestamp)
                 enqueue!(timestamp)
                 {timestamp, :existing}

               timestamp ->
                 # Also repairs legacy placeholders with no durable job.
                 enqueue!(timestamp)
                 {timestamp, :existing}
             end
           end) do
      broadcast(
        timestamp,
        if(disposition == :created, do: :timestamp_created, else: :timestamp_updated)
      )

      {:ok, timestamp, disposition}
    end
  end

  def retry(%Timestamp{id: id}), do: retry(id)

  def retry(id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      initial ->
        result =
          Repo.transaction(fn ->
            lock_video(identity_key(initial))
            timestamp = Repo.get!(Timestamp, initial.id)
            context = timestamp.processing_context || %{}

            allowed =
              String.contains?(timestamp.content || "", "0:00 UNWATCHED") and
                context["manual_retry_used"] != true and
                (context["manual_retry_count"] || 0) < 1 and
                not active_job?(timestamp.id)

            unless allowed, do: Repo.rollback(:retry_not_allowed)

            context =
              context
              |> Map.put("manual_retry_used", true)
              |> Map.put("manual_retry_last_at", DateTime.to_iso8601(DateTime.utc_now()))

            timestamp = reset!(timestamp, context)
            enqueue!(timestamp)
            timestamp
          end)

        case result do
          {:ok, timestamp} ->
            broadcast(timestamp)
            {:ok, timestamp}

          error ->
            error
        end
    end
  end

  def get(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: Repo.get(Timestamp, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} when integer > 0 -> get(integer)
      _ -> nil
    end
  end

  def get(_), do: nil

  def response(%Timestamp{} = timestamp) do
    base = %{
      timestamp_id: timestamp.id,
      submission_id: timestamp.id,
      status_url: "/api/submissions/#{timestamp.id}",
      phase: timestamp.processing_phase,
      estimated_cost_usd: CostEstimator.serialize(timestamp.estimated_cost_usd)
    }

    case timestamp.processing_status do
      :ready ->
        Map.merge(base, %{
          status: "success",
          response: timestamp.distilled_content || timestamp.content
        })

      :failed ->
        details = FailureMessage.for_timestamp(timestamp)
        message = (timestamp.processing_context || %{})["public_error"] || details.summary
        Map.merge(base, %{status: "error", message: message})

      :processing ->
        Map.merge(base, %{
          status: "processing",
          message: "Submission saved and queued for processing."
        })
    end
  end

  def update!(%Timestamp{} = timestamp, attrs) do
    updated = timestamp |> Timestamp.changeset(attrs) |> Repo.update!()
    broadcast(updated)
    updated
  end

  def broadcast(timestamp, event \\ :timestamp_updated) do
    Phoenix.PubSub.broadcast(DragNStamp.PubSub, "timestamps", {event, timestamp})
  end

  @doc "Reconciles legacy placeholders and jobs that exhausted attempts after a hard crash."
  def recover do
    ids = Repo.all(from t in Timestamp, where: t.processing_status == :processing, select: t.id)

    Enum.each(ids, fn id ->
      initial = Repo.get!(Timestamp, id)

      result =
        Repo.transaction(fn ->
          lock_video(identity_key(initial))
          timestamp = Repo.get!(Timestamp, id)

          if timestamp.processing_status == :processing do
            latest =
              Repo.one(from j in jobs_for(id), order_by: [desc: j.id], limit: 1)

            cond do
              active_job?(id) ->
                nil

              is_nil(latest) ->
                enqueue!(timestamp)
                nil

              true ->
                message =
                  "Processing stopped after its retry limit. Submit the video again to retry."

                context = Map.put(timestamp.processing_context || %{}, "public_error", message)

                timestamp
                |> Timestamp.changeset(%{
                  processing_status: :failed,
                  processing_phase: "failed",
                  processing_error: message,
                  processing_context: context
                })
                |> Repo.update!()
            end
          end
        end)

      case result do
        {:ok, %Timestamp{} = timestamp} -> broadcast(timestamp)
        _ -> :ok
      end
    end)

    :ok
  end

  defp find_existing(identity) do
    Repo.one(
      from t in Timestamp,
        where: t.video_id == ^identity.video_id or t.url == ^identity.url,
        order_by: [desc: fragment("? = 'ready'", t.processing_status), asc: t.id],
        limit: 1
    )
  end

  defp insert_timestamp!(identity, attrs) do
    params =
      Map.merge(identity, %{
        channel_name: name(attrs, :channel_name),
        submitter_username: name(attrs, :submitter_username),
        processing_status: :processing,
        processing_phase: "queued"
      })

    case SubmissionLimit.insert_if_available(Timestamp.changeset(%Timestamp{}, params)) do
      {:ok, timestamp} -> timestamp
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reset!(timestamp, context \\ nil) do
    context =
      (context || timestamp.processing_context || %{})
      |> Map.drop([
        "generation_model",
        "caption_attempts",
        "captions_summary",
        "public_error",
        "output_bound_seconds",
        "last_failure",
        "attempt",
        "distillation_failed"
      ])

    timestamp
    |> Timestamp.changeset(%{
      content: nil,
      distilled_content: nil,
      estimated_cost_usd: nil,
      processing_status: :processing,
      processing_phase: "queued",
      processing_error: nil,
      processing_context: context
    })
    |> Repo.update!()
  end

  defp enqueue!(timestamp) do
    timestamp.id
    |> then(&Worker.new(%{timestamp_id: &1}))
    |> Oban.insert()
    |> case do
      {:ok, job} -> job
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp active_job?(id), do: Repo.exists?(from j in jobs_for(id), where: j.state in @active_states)

  defp jobs_for(id) do
    worker = Oban.Worker.to_string(Worker)

    from j in Oban.Job,
      where: j.worker == ^worker and fragment("?->>'timestamp_id'", j.args) == ^to_string(id)
  end

  defp lock_video(key) do
    # The lock lasts only for the acceptance transaction, never during external
    # IO. It works across app instances without Erlang cluster membership.
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "submission:" <> key
    ])
  end

  defp identity_key(timestamp) do
    case URL.parse(timestamp.url) do
      {:ok, identity} -> identity.video_id
      _ -> timestamp.video_id || timestamp.url
    end
  end

  defp name(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) ->
        if(String.trim(value) == "", do: "anonymous", else: String.trim(value))

      _ ->
        "anonymous"
    end
  end
end
