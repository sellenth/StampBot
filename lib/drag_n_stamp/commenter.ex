defmodule DragNStamp.Commenter do
  @moduledoc """
  Claims and posts YouTube comments with durable duplicate and rate-limit guards.

  A pending claim is deliberately not reclaimed automatically: an interrupted
  network call may already have published a comment on YouTube.
  """

  import Ecto.Query

  alias DragNStamp.{PublicationPolicy, Repo, Timestamp, YouTubeAPI}

  @cooldown_seconds 60
  @daily_attempt_cap 5

  @doc """
  Attempts to post a YouTube comment for the given timestamp.

  Requires explicit server-side publication authority; the default is denied.
  Atomically claims an eligible record and account allowance before network IO. Callers that encounter
  a pending or completed attempt skip without changing its durable status.
  `:post_fun` accepts a two-argument function for an alternative posting adapter.
  """
  def post_for_timestamp(%Timestamp{} = timestamp, opts \\ []) do
    authority = Keyword.get(opts, :authority)

    with :ok <- PublicationPolicy.authorize(authority) do
      case claim(timestamp, authority, Keyword.get(opts, :expected_digest)) do
        {:ok, claimed, attempt} ->
          case do_post(claimed, opts) do
            {:ok, response} -> handle_success(claimed, attempt, response)
            {:error, reason} -> handle_failure(claimed, attempt, reason)
          end

        {:skip, reason, latest} ->
          {:ok, latest, {:skipped, reason}}

        {:blocked, reason, latest} ->
          {:ok, latest, {:error, reason}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp claim(timestamp, authority, expected_digest) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, latest} <- reload(timestamp),
         :ok <- ensure_ready(latest),
         :ok <- validate_approved_content(latest, expected_digest),
         :ok <- enforce_limits(latest, now) do
      dedupe_key = PublicationPolicy.content_digest(latest)

      cooldown_cutoff = DateTime.add(now, -@cooldown_seconds, :second)
      daily_cutoff = DateTime.add(now, -86_400, :second)

      eligible =
        from t in Timestamp,
          where:
            t.id == ^latest.id and t.processing_status == :ready and
              t.youtube_comment_status not in [:pending, :succeeded] and
              is_nil(t.youtube_comment_external_id) and
              t.url == ^latest.url and t.distilled_content == ^latest.distilled_content and
              (is_nil(t.youtube_comment_last_attempt_at) or
                 t.youtube_comment_last_attempt_at <= ^cooldown_cutoff) and
              (is_nil(t.youtube_comment_last_attempt_at) or
                 t.youtube_comment_last_attempt_at <= ^daily_cutoff or
                 t.youtube_comment_attempts < @daily_attempt_cap),
          select: t

      changes = [
        set: [
          youtube_comment_status: :pending,
          youtube_comment_error: nil,
          youtube_comment_last_attempt_at: now,
          youtube_comment_dedupe_key: dedupe_key,
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ],
        inc: [youtube_comment_attempts: 1]
      ]

      PublicationPolicy.claim(authority, fn ->
        case Repo.update_all(eligible, changes) do
          {1, [claimed]} -> {:ok, claimed}
          {0, []} -> claim_changed(latest, now)
        end
      end)
    end
  end

  defp validate_approved_content(_timestamp, nil), do: :ok

  defp validate_approved_content(timestamp, digest) do
    if PublicationPolicy.content_digest(timestamp) == digest,
      do: :ok,
      else: {:error, :publication_content_changed}
  end

  defp reload(%Timestamp{id: id}) when not is_nil(id) do
    case Repo.get(Timestamp, id) do
      nil -> {:error, :not_found}
      latest -> {:ok, latest}
    end
  end

  defp reload(_), do: {:error, :not_found}

  defp claim_changed(timestamp, now) do
    with {:ok, latest} <- reload(timestamp),
         :ok <- ensure_ready(latest),
         :ok <- enforce_limits(latest, now) do
      # The content or another eligibility field changed after it was read.
      # Let a later caller inspect the new record instead of posting stale text.
      {:skip, :claim_changed, latest}
    end
  end

  defp ensure_ready(%Timestamp{} = timestamp) do
    cond do
      timestamp.youtube_comment_status == :succeeded or
          not is_nil(timestamp.youtube_comment_external_id) ->
        {:skip, :already_commented, timestamp}

      timestamp.youtube_comment_status == :pending ->
        {:skip, :in_flight, timestamp}

      timestamp.processing_status != :ready ->
        {:skip, :not_ready, timestamp}

      not is_binary(timestamp.distilled_content) or
          String.trim(timestamp.distilled_content) == "" ->
        {:blocked, :no_distilled_content, timestamp}

      not is_binary(timestamp.url) ->
        {:blocked, :invalid_data, timestamp}

      String.contains?(timestamp.distilled_content, "0:00 UNWATCHED") ->
        {:skip, :unwatched, timestamp}

      true ->
        :ok
    end
  end

  defp enforce_limits(%Timestamp{} = timestamp, now) do
    elapsed =
      case timestamp.youtube_comment_last_attempt_at do
        nil -> nil
        last -> DateTime.diff(now, last, :second)
      end

    cond do
      is_integer(elapsed) and elapsed < @cooldown_seconds ->
        {:blocked, :cooldown, timestamp}

      is_integer(elapsed) and elapsed < 86_400 and
          timestamp.youtube_comment_attempts >= @daily_attempt_cap ->
        {:blocked, :rate_limited, timestamp}

      true ->
        :ok
    end
  end

  defp do_post(%Timestamp{url: url, distilled_content: content}, opts) do
    post_fun = Keyword.get(opts, :post_fun, &YouTubeAPI.post_comment/2)

    case post_fun.(url, content) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp handle_success(timestamp, attempt, response) do
    finish_claim(
      timestamp,
      attempt,
      [
        youtube_comment_status: :succeeded,
        youtube_comment_error: nil,
        youtube_comment_external_id: extract_comment_id(response)
      ],
      :ok
    )
  end

  defp handle_failure(timestamp, attempt, reason) do
    status = if reason == :auth_required, do: :auth_required, else: :failed

    finish_claim(
      timestamp,
      attempt,
      [youtube_comment_status: status, youtube_comment_error: Atom.to_string(reason)],
      {:error, reason}
    )
  end

  defp finish_claim(timestamp, attempt, changes, outcome) do
    owned =
      from t in Timestamp,
        where:
          t.id == ^timestamp.id and t.youtube_comment_status == :pending and
            is_nil(t.youtube_comment_external_id) and
            t.youtube_comment_dedupe_key == ^timestamp.youtube_comment_dedupe_key and
            t.youtube_comment_last_attempt_at == ^timestamp.youtube_comment_last_attempt_at and
            t.youtube_comment_attempts == ^timestamp.youtube_comment_attempts,
        select: t

    changes =
      Keyword.put(
        changes,
        :updated_at,
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )

    Repo.transaction(fn ->
      case Repo.update_all(owned, set: changes) do
        {1, [updated]} ->
          PublicationPolicy.finish_attempt!(attempt, updated)
          {:ok, updated, outcome}

        {0, []} ->
          case reload(timestamp) do
            {:ok, latest} -> {:ok, latest, {:skipped, :claim_changed}}
            error -> error
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_error(reason) do
    case reason do
      :auth_required ->
        :auth_required

      :quota ->
        :quota

      :bad_request ->
        :bad_request

      :unauthorized ->
        :auth_required

      :cooldown ->
        :cooldown

      :rate_limited ->
        :rate_limited

      :invalid_data ->
        :invalid_data

      other when is_binary(other) ->
        try do
          String.to_existing_atom(other)
        rescue
          ArgumentError -> :unknown
        end

      _other ->
        :unknown
    end
  end

  defp extract_comment_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_comment_id(%{"items" => [%{"id" => id} | _]}), do: id
  defp extract_comment_id(_), do: nil
end
