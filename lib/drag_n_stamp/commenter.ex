defmodule DragNStamp.Commenter do
  @moduledoc """
  Handles idempotent, rate-limited posting of YouTube comments for a Timestamp.
  Adds spam prevention and maps API failures to durable status fields.
  """

  require Logger
  alias DragNStamp.{Repo, Timestamp, YouTubeAPI}

  @cooldown_seconds 60
  @daily_attempt_cap 5

  @doc """
  Attempts to post a YouTube comment for the given timestamp.

  - Idempotent via `youtube_comment_dedupe_key`.
  - Applies cooldown and daily attempt cap.
  - Updates status fields on the record and returns the updated struct.
  """
  def post_for_timestamp(%Timestamp{} = ts) do
    with {:ok, ts} <- maybe_reload(ts),
         {:ok, _} <- ensure_ready(ts),
         {:ok, dedupe_key} <- compute_dedupe_key(ts),
         :ok <- enforce_limits(ts),
         {:ok, ts} <- mark_pending(ts, dedupe_key),
         {:ok, result} <- do_post(ts) do
      handle_success(ts, result)
    else
      {:skip, reason, %Timestamp{} = ts} ->
        {:ok, ts, {:skipped, reason}}

      {:error, reason} ->
        with {:ok, %Timestamp{} = updated} <- handle_failure(ts, reason) do
          {:ok, updated, {:error, reason}}
        else
          other -> other
        end
    end
  end

  defp maybe_reload(%Timestamp{id: id}) do
    {:ok, Repo.get!(Timestamp, id)}
  end

  defp ensure_ready(%Timestamp{} = ts) do
    cond do
      ts.youtube_comment_status in [:succeeded] or not is_nil(ts.youtube_comment_external_id) ->
        {:skip, :already_commented, ts}

      is_nil(ts.distilled_content) or String.trim(to_string(ts.distilled_content)) == "" ->
        {:error, :no_distilled_content}

      true ->
        {:ok, :ready}
    end
  end

  defp compute_dedupe_key(%Timestamp{url: url, distilled_content: content}) when is_binary(url) and is_binary(content) do
    key = :crypto.hash(:sha256, url <> "|" <> content) |> Base.encode16(case: :lower)
    {:ok, key}
  end

  defp compute_dedupe_key(_), do: {:error, :invalid_data}

  defp enforce_limits(%Timestamp{} = ts) do
    now = DateTime.utc_now()

    too_soon =
      case ts.youtube_comment_last_attempt_at do
        nil -> false
        %DateTime{} = last -> DateTime.diff(now, last, :second) < @cooldown_seconds
      end

    if too_soon do
      {:error, :cooldown}
    else
      recent_cap_hit =
        case ts.youtube_comment_last_attempt_at do
          nil -> false
          %DateTime{} = last -> DateTime.diff(now, last, :second) < 86_400 and ts.youtube_comment_attempts >= @daily_attempt_cap
        end

      if recent_cap_hit, do: {:error, :rate_limited}, else: :ok
    end
  end

  defp mark_pending(%Timestamp{} = ts, dedupe_key) do
    changes = %{
      youtube_comment_status: :pending,
      youtube_comment_last_attempt_at: DateTime.utc_now(),
      youtube_comment_attempts: (ts.youtube_comment_attempts || 0) + 1,
      youtube_comment_dedupe_key: dedupe_key
    }

    case Repo.update(Timestamp.changeset(ts, changes)) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} = err -> err
    end
  end

  defp do_post(%Timestamp{url: url, distilled_content: content}) do
    case YouTubeAPI.post_comment(url, content) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp handle_success(%Timestamp{} = ts, resp) do
    external_id = extract_comment_id(resp)
    changes = %{
      youtube_comment_status: :succeeded,
      youtube_comment_error: nil,
      youtube_comment_external_id: external_id
    }

    case Repo.update(Timestamp.changeset(ts, changes)) do
      {:ok, updated} -> {:ok, updated, :ok}
      other -> other
    end
  end

  defp handle_failure(%Timestamp{} = ts, reason) do
    status =
      case reason do
        :auth_required -> :auth_required
        _ -> :failed
      end

    changes = %{
      youtube_comment_status: status,
      youtube_comment_error: to_string(reason)
    }

    Repo.update(Timestamp.changeset(ts, changes))
  end

  defp normalize_error(reason) do
    case reason do
      :auth_required -> :auth_required
      :quota -> :quota
      :bad_request -> :bad_request
      :unauthorized -> :auth_required
      :cooldown -> :cooldown
      :rate_limited -> :rate_limited
      :invalid_data -> :invalid_data
      other when is_binary(other) ->
        try do
          String.to_existing_atom(other)
        rescue
          ArgumentError -> :unknown
        end
      _other -> :unknown
    end
  end

  defp extract_comment_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_comment_id(%{"items" => [%{"id" => id} | _]}), do: id
  defp extract_comment_id(_), do: nil
end
