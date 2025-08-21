defmodule DragNStampWeb.PageController do
  use DragNStampWeb, :controller
  require Logger

  def process_youtube_url(conn, %{"path" => path}) do
    # Reconstruct the original YouTube URL
    query_string = conn.query_string
    full_path = Enum.join(path, "/")

    youtube_url =
      if query_string != "" do
        "https://www.youtube.com/#{full_path}?#{query_string}"
      else
        "https://www.youtube.com/#{full_path}"
      end

    Logger.info("Processing YouTube URL redirect: #{youtube_url}")

    # Fire async request to gemini endpoint
    Task.start(fn ->
      fire_gemini_request(youtube_url)
    end)

    # Immediately redirect back to YouTube
    redirect(conn, external: youtube_url)
  end

  defp fire_gemini_request(youtube_url) do
    # Get the base URL for our API endpoint
    base_url = DragNStampWeb.Endpoint.url()
    api_endpoint = "#{base_url}/api/gemini"

    # Extract channel name (basic extraction from URL if possible, otherwise anonymous)
    channel_name = extract_channel_from_url(youtube_url) || "anonymous"

    payload = %{
      url: youtube_url,
      channel_name: channel_name,
      submitter_username: "domain-swap"
    }

    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!(payload)

    # Fire and forget HTTP request to our own API
    case Finch.build(:post, api_endpoint, headers, body)
         |> Finch.request(DragNStamp.Finch, receive_timeout: 10_000) do
      {:ok, _response} ->
        Logger.info("Successfully fired gemini request for: #{youtube_url}")

      {:error, reason} ->
        Logger.error("Failed to fire gemini request: #{inspect(reason)}")
    end
  end

  defp extract_channel_from_url(url) do
    # Try to extract channel info from URL patterns
    cond do
      String.contains?(url, "/@") ->
        # Pattern: youtube.com/@channelname/video
        url
        |> String.split("/@")
        |> Enum.at(1)
        |> case do
          nil -> nil
          part -> part |> String.split("/") |> Enum.at(0)
        end

      String.contains?(url, "/c/") ->
        # Pattern: youtube.com/c/channelname
        url
        |> String.split("/c/")
        |> Enum.at(1)
        |> case do
          nil -> nil
          part -> part |> String.split("/") |> Enum.at(0)
        end

      true ->
        # Can't extract from URL, will be anonymous
        nil
    end
  end
end
