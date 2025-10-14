defmodule DragNStamp.SEO.VideoMetadata do
  @moduledoc """
  Fetches and persists YouTube video metadata for timestamp records.
  Attempts to use the YouTube Data API when an API key is configured, and
  falls back to the oEmbed endpoint otherwise.
  """

  require Logger

  alias DragNStamp.{Repo, Timestamp}

  @youtube_api "https://www.googleapis.com/youtube/v3/videos"
  @youtube_oembed "https://www.youtube.com/oembed"

  @doc """
  Ensures the given timestamp has video metadata persisted.
  Returns `{:ok, %Timestamp{}}` with metadata populated or `{:error, reason}`.
  """
  @spec ensure_metadata(Timestamp.t()) :: {:ok, Timestamp.t()} | {:error, term()}
  def ensure_metadata(%Timestamp{video_title: title, video_thumbnail_url: thumb} = timestamp)
      when is_binary(title) and title != "" and is_binary(thumb) and thumb != "" do
    {:ok, timestamp}
  end

  def ensure_metadata(%Timestamp{} = timestamp) do
    with {:ok, video_id} <- extract_video_id(timestamp.url),
         {:ok, metadata} <- fetch_metadata(video_id, timestamp.url),
         {:ok, updated} <- persist_metadata(timestamp, Map.put(metadata, :video_id, video_id)) do
      {:ok, updated}
    else
      {:error, reason} ->
        Logger.warning("Failed to fetch metadata for #{timestamp.url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Attempt to fetch metadata without persisting it.
  """
  @spec fetch_metadata(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_metadata(video_id, video_url) do
    case fetch_from_api(video_id) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, api_error} ->
        Logger.debug("YouTube API fallback due to: #{inspect(api_error)}")
        fetch_from_oembed(video_url)
    end
  end

  @doc """
  Extract a YouTube video ID from a URL.
  """
  @spec extract_video_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_video_id(nil), do: {:error, :no_url}

  def extract_video_id(url) when is_binary(url) do
    cond do
      String.contains?(url, "watch?v=") ->
        case Regex.run(~r/[?&]v=([^&]+)/, url) do
          [_, id] -> {:ok, id}
          _ -> {:error, :invalid_url}
        end

      String.contains?(url, "youtu.be/") ->
        case Regex.run(~r/youtu\.be\/([^?&]+)/, url) do
          [_, id] -> {:ok, id}
          _ -> {:error, :invalid_url}
        end

      true ->
        {:error, :invalid_url}
    end
  end

  def extract_video_id(_), do: {:error, :invalid_url}

  @doc """
  Parse an ISO8601 duration string into seconds.
  Returns `nil` when parsing fails.
  """
  @spec parse_duration(String.t() | nil) :: integer() | nil
  def parse_duration(nil), do: nil

  def parse_duration(duration) when is_binary(duration) do
    with ["PT" <> _ = format] <- [String.upcase(duration)],
         {:ok, captures} <- extract_duration_parts(format) do
      Enum.reduce(captures, 0, fn
        {value, unit}, acc when unit in ["H", "M", "S"] -> acc + duration_value(value, unit)
        _, acc -> acc
      end)
    else
      _ -> nil
    end
  end

  def parse_duration(_), do: nil

  defp extract_duration_parts(duration) do
    regex = ~r/(?<value>\d+)(?<unit>[HMS])/u

    parts =
      Regex.scan(regex, duration)
      |> Enum.map(fn [_, value, unit] -> {String.to_integer(value), unit} end)

    if parts == [] do
      {:error, :invalid_duration}
    else
      {:ok, parts}
    end
  rescue
    ArgumentError -> {:error, :invalid_duration}
  end

  defp duration_value(value, "H"), do: value * 3600
  defp duration_value(value, "M"), do: value * 60
  defp duration_value(value, "S"), do: value
  defp duration_value(_value, _unit), do: 0

  defp fetch_from_api(video_id) do
    case System.get_env("YOUTUBE_DATA_API_KEY") do
      nil -> {:error, :no_api_key}
      "" -> {:error, :no_api_key}
      api_key -> do_fetch_from_api(video_id, api_key)
    end
  end

  defp do_fetch_from_api(video_id, api_key) do
    params =
      URI.encode_query(%{
        "part" => "snippet,contentDetails",
        "id" => video_id,
        "key" => api_key
      })

    url = @youtube_api <> "?" <> params

    request = Finch.build(:get, url, headers())

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, payload} <- Jason.decode(body),
             {:ok, metadata} <- build_metadata_from_api(payload) do
          {:ok, metadata}
        else
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("YouTube API returned status #{status}: #{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_metadata_from_api(%{"items" => [item | _]}) do
    snippet = Map.get(item, "snippet", %{})
    content = Map.get(item, "contentDetails", %{})

    metadata = %{
      video_title: Map.get(snippet, "title"),
      video_description: Map.get(snippet, "description"),
      video_thumbnail_url: extract_thumbnail(snippet),
      video_duration_seconds: parse_duration(Map.get(content, "duration")),
      video_published_at: parse_datetime(Map.get(snippet, "publishedAt")),
      channel_name: Map.get(snippet, "channelTitle")
    }

    {:ok, metadata}
  end

  defp build_metadata_from_api(_), do: {:error, :no_items}

  @doc """
  Fetch only the duration (in seconds) for a given YouTube `video_id` using the
  YouTube Data API. Returns `{:ok, seconds}` when available, or `{:error, reason}`.

  This does not fall back to oEmbed, since duration is not provided there.
  """
  @spec fetch_duration_seconds(String.t()) :: {:ok, integer()} | {:error, term()}
  def fetch_duration_seconds(video_id) when is_binary(video_id) do
    case System.get_env("YOUTUBE_DATA_API_KEY") do
      nil -> {:error, :no_api_key}
      "" -> {:error, :no_api_key}
      api_key -> do_fetch_duration_seconds(video_id, api_key)
    end
  end

  def fetch_duration_seconds(_), do: {:error, :invalid_video_id}

  defp do_fetch_duration_seconds(video_id, api_key) do
    params =
      URI.encode_query(%{
        "part" => "contentDetails",
        "id" => video_id,
        "key" => api_key
      })

    url = @youtube_api <> "?" <> params

    request = Finch.build(:get, url, headers())

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, payload} <- Jason.decode(body),
             %{"items" => [item | _]} <- payload,
             %{"contentDetails" => %{"duration" => iso_duration}} <- item,
             seconds when is_integer(seconds) <- parse_duration(iso_duration) do
          {:ok, seconds}
        else
          %{"items" => []} -> {:error, :no_items}
          _ -> {:error, :parse_error}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("YouTube API (duration) returned status #{status}: #{body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_from_oembed(video_url) do
    params = URI.encode_query(%{"url" => video_url, "format" => "json"})
    url = @youtube_oembed <> "?" <> params

    request = Finch.build(:get, url, headers())

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, payload} <- Jason.decode(body) do
          {:ok,
           %{
             video_title: Map.get(payload, "title"),
             video_description: nil,
             video_thumbnail_url: Map.get(payload, "thumbnail_url"),
             video_duration_seconds: nil,
             video_published_at: nil,
             channel_name: Map.get(payload, "author_name")
           }}
        else
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_metadata(%Timestamp{} = timestamp, attrs) do
    attrs =
      attrs
      |> Map.take([
        :video_id,
        :video_title,
        :video_description,
        :video_thumbnail_url,
        :video_duration_seconds,
        :video_published_at,
        :channel_name
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    changeset = Timestamp.changeset(timestamp, attrs)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp headers do
    [{"User-Agent", "StampBot/SEO-Static-Pages"}]
  end

  defp extract_thumbnail(%{"thumbnails" => thumbnails}) when is_map(thumbnails) do
    Enum.reduce_while(["maxres", "standard", "high", "medium", "default"], nil, fn key, _acc ->
      case Map.get(thumbnails, key) do
        %{"url" => url} -> {:halt, url}
        _ -> {:cont, nil}
      end
    end)
  end

  defp extract_thumbnail(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
