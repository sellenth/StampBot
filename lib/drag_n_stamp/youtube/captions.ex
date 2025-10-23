defmodule DragNStamp.YouTube.Captions do
  @moduledoc """
  Lightweight YouTube captions fetcher that prefers human-authored English
  subtitles and falls back to auto-generated transcripts when necessary.
  """

  require Logger

  alias DragNStamp.YouTube.Innertube

  @timedtext_url "https://www.youtube.com/api/timedtext"
  @timedtext_fallback_attempts [
    %{"lang_code" => "en"},
    %{"lang_code" => "en", "kind" => "asr"},
    %{"lang_code" => "en-US"},
    %{"lang_code" => "en-US", "kind" => "asr"},
    %{"lang_code" => "en-GB"},
    %{"lang_code" => "en-GB", "kind" => "asr"}
  ]

  @doc """
  Attempts to fetch the most useful caption track for the given YouTube `video_id`.

  Returns `{:ok, %{track: map(), segments: list()}}` on success or
  `{:error, reason, context}` on failure. The `context` map contains additional
  diagnostic information that can be persisted for later analysis.
  """
  @spec fetch_transcript(String.t()) ::
          {:ok, %{track: map(), segments: list()}}
          | {:error, term(), map()}
  def fetch_transcript(video_id) when is_binary(video_id) do
    with {:ok, tracks, list_context} <- list_tracks(video_id),
         {:ok, track} <- choose_track(tracks),
         {:ok, segments} <- download_track(video_id, track) do
      context =
        list_context
        |> Map.put(:chosen_track, scrub_track_for_context(track))
        |> Map.put(:segment_count, length(segments))
        |> Map.put(:stage, :transcript_ready)

      {:ok, %{track: track, segments: segments, context: context}}
    else
      {:error, :no_tracks, context} ->
        case fallback_download(video_id) do
          {:ok, track, segments, attempts} ->
            merged_context =
              context
              |> Map.put(:fallback_used, true)
              |> Map.put(:fallback_attempts, attempts)
              |> Map.put(:segment_count, length(segments))
              |> Map.put(:chosen_track, scrub_track_for_context(track))
              |> Map.put(:stage, :transcript_ready)

            {:ok, %{track: track, segments: segments, context: merged_context}}

          {:error, reason, attempts} ->
            merged_context =
              context
              |> Map.put(:fallback_used, true)
              |> Map.put(:fallback_attempts, attempts)

            {:error, reason, merged_context}
        end

      {:error, reason, context} ->
        {:error, reason, context}

      {:error, reason} ->
        {:error, reason, %{stage: :choose_track}}
    end
  end

  def fetch_transcript(_), do: {:error, :invalid_video_id, %{stage: :input_validation}}

  defp list_tracks(video_id) do
    params =
      URI.encode_query(%{
        "type" => "list",
        "v" => video_id
      })

    url = @timedtext_url <> "?" <> params
    request = Finch.build(:get, url, headers())

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        tracks = parse_track_listing(body)

        if tracks == [] do
          {:error, :no_tracks, %{stage: :list_tracks, url: url, body_length: byte_size(body)}}
        else
          {:ok, tracks,
           %{
             stage: :list_tracks,
             track_count: length(tracks),
             video_id: video_id
           }}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status},
         %{stage: :list_tracks, status: status, body: truncate(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}, %{stage: :list_tracks, error: inspect(reason)}}
    end
  end

  defp parse_track_listing(xml) when is_binary(xml) do
    Regex.scan(~r/<track\b([^>]*)\/>/, xml)
    |> Enum.map(fn [_, attrs] ->
      Regex.scan(~r/([a-zA-Z0-9_:-]+)="([^"]*)"/, attrs)
      |> Enum.reduce(%{}, fn [_, key, value], acc ->
        Map.put(acc, key, html_unescape(value))
      end)
    end)
  end

  defp choose_track([]), do: {:error, :no_tracks_available}

  defp choose_track(tracks) when is_list(tracks) do
    track =
      tracks
      |> Enum.with_index()
      |> Enum.min_by(fn {track, index} ->
        {
          language_rank(Map.get(track, "lang_code")),
          kind_rank(Map.get(track, "kind")),
          default_rank(Map.get(track, "lang_default")),
          index
        }
      end)
      |> elem(0)

    {:ok, track}
  end

  defp language_rank(nil), do: 3

  defp language_rank(code) when is_binary(code) do
    normalized = String.downcase(code)

    cond do
      normalized in ["en", "en-us", "en-gb"] -> 0
      String.starts_with?(normalized, "en") -> 1
      true -> 2
    end
  end

  defp language_rank(_), do: 3

  defp kind_rank(nil), do: 0
  defp kind_rank("asr"), do: 1
  defp kind_rank(_other), do: 2

  defp default_rank(value) when is_binary(value) do
    if String.downcase(value) == "true", do: 0, else: 1
  end

  defp default_rank(_), do: 1

  defp download_track(video_id, track) do
    params =
      %{
        "v" => video_id,
        "lang" => Map.get(track, "lang_code"),
        "fmt" => "json3"
      }
      |> maybe_put("kind", Map.get(track, "kind"))
      |> maybe_put("name", Map.get(track, "name"))

    url = @timedtext_url <> "?" <> URI.encode_query(params)
    request = Finch.build(:get, url, headers())

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, payload} <- Jason.decode(body),
             {:ok, segments} <- extract_segments(payload) do
          {:ok, segments}
        else
          {:error, reason} ->
            {:error, {:invalid_caption_payload, reason},
             %{
               stage: :download_track,
               url: url,
               reason: inspect(reason)
             }}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status},
         %{stage: :download_track, status: status, body: truncate(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}, %{stage: :download_track, error: inspect(reason)}}
    end
  end

  defp scrub_track_for_context(track) when is_map(track) do
    track
    |> Enum.map(fn {key, value} ->
      safe_value =
        case value do
          binary when is_binary(binary) -> truncate(binary)
          other -> other
        end

      {key, safe_value}
    end)
    |> Enum.into(%{})
  end

  defp scrub_track_for_context(_), do: %{}

  defp extract_segments(%{"events" => events}) when is_list(events) do
    segments =
      events
      |> Enum.map(&event_to_segment/1)
      |> Enum.filter(&(&1.text != ""))

    if segments == [] do
      {:error, :empty_segments}
    else
      {:ok, segments}
    end
  end

  defp extract_segments(_), do: {:error, :unexpected_payload}

  defp event_to_segment(event) when is_map(event) do
    start_ms = Map.get(event, "tStartMs", 0)
    duration_ms = Map.get(event, "dDurationMs", 0)
    segs = Map.get(event, "segs", [])

    text =
      segs
      |> Enum.map(&Map.get(&1, "utf8", ""))
      |> Enum.reject(&(&1 in ["\n", "\r\n"]))
      |> Enum.join()
      |> String.trim()

    %{
      start_ms: start_ms,
      end_ms: start_ms + duration_ms,
      text: text
    }
  end

  defp headers do
    [
      {"User-Agent", "StampBot/1.0 (caption fetcher)"}
    ]
  end

  defp maybe_put(map, _key, value) when value in [nil, "", false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp html_unescape(value) when is_binary(value) do
    Plug.HTML.html_unescape(value)
  end

  defp html_unescape(other), do: other

  defp truncate(nil), do: nil

  defp truncate(binary) when is_binary(binary) do
    if byte_size(binary) <= 500 do
      binary
    else
      binary
      |> binary_part(0, 500)
      |> Kernel.<>("…")
    end
  end

  defp fallback_download(video_id) do
    case fallback_timedtext(video_id) do
      {:ok, track, segments, attempts} ->
        {:ok, track, segments, attempts}

      {:error, :no_tracks, attempts} ->
        use_innertube(video_id, attempts)

      {:error, reason, attempts} ->
        {:error, reason, attempts}
    end
  end

  defp fallback_timedtext(video_id) do
    Enum.reduce_while(@timedtext_fallback_attempts, {:error, :no_tracks, []}, fn attempt,
                                                                                {:error, :no_tracks,
                                                                                 failures} ->
      case download_track(video_id, attempt) do
        {:ok, segments} ->
          info = %{
            attempt: scrub_track_for_context(attempt),
            result: :ok,
            source: :timedtext_fallback
          }

          {:halt, {:ok, attempt, segments, Enum.reverse([info | failures])}}

        {:error, reason, attempt_context} ->
          failure = %{
            attempt: scrub_track_for_context(attempt),
            result: reason,
            context: attempt_context,
            source: :timedtext_fallback
          }

          {:cont, {:error, :no_tracks, [failure | failures]}}

        {:error, reason} ->
          failure = %{
            attempt: scrub_track_for_context(attempt),
            result: reason,
            source: :timedtext_fallback
          }

          {:cont, {:error, :no_tracks, [failure | failures]}}
      end
    end)
    |> case do
      {:ok, attempt, segments, attempts} ->
        {:ok, attempt, segments, attempts}

      {:error, reason, attempts} ->
        {:error, reason, Enum.reverse(attempts)}
    end
  end

  defp use_innertube(video_id, attempts) do
    case Innertube.fetch_transcript(video_id) do
      {:ok, %{segments: segments, track: track, context: context}} ->
        entry = %{
          attempt: %{"source" => "innertube"},
          result: :ok,
          context: context
        }

        {:ok, track, segments, attempts ++ [entry]}

      {:error, reason, context} ->
        entry = %{
          attempt: %{"source" => "innertube"},
          result: reason,
          context: context
        }

        {:error, reason, attempts ++ [entry]}
    end
  end
end
