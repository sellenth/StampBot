defmodule DragNStampWeb.PageController do
  use DragNStampWeb, :controller
  require Logger

  def sitemap(conn, _params) do
    base_url = "https://stamp-bot.com"
    current_date = DateTime.utc_now() |> DateTime.to_iso8601()
    
    sitemap_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"
            xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">
      <url>
        <loc>#{base_url}/</loc>
        <lastmod>#{current_date}</lastmod>
        <changefreq>daily</changefreq>
        <priority>1.0</priority>
        <image:image>
          <image:loc>#{base_url}/images/og-image.jpg</image:loc>
          <image:title>StampBot YouTube Timestamp Generator</image:title>
          <image:caption>AI-powered YouTube timestamp generation tool</image:caption>
        </image:image>
      </url>
      <url>
        <loc>#{base_url}/feed</loc>
        <lastmod>#{current_date}</lastmod>
        <changefreq>hourly</changefreq>
        <priority>0.8</priority>
      </url>
      <url>
        <loc>#{base_url}/leaderboard</loc>
        <lastmod>#{current_date}</lastmod>
        <changefreq>daily</changefreq>
        <priority>0.7</priority>
      </url>
      <url>
        <loc>#{base_url}/more-info</loc>
        <lastmod>#{current_date}</lastmod>
        <changefreq>weekly</changefreq>
        <priority>0.6</priority>
      </url>
      <url>
        <loc>#{base_url}/extension</loc>
        <lastmod>#{current_date}</lastmod>
        <changefreq>monthly</changefreq>
        <priority>0.5</priority>
      </url>
    </urlset>
    """
    
    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, sitemap_xml)
  end

  def extension(conn, _params) do
    # Render a static page for the extension without LiveView/WebSockets
    base_url = DragNStampWeb.Endpoint.url()
    api_endpoint = "#{base_url}/api/gemini"
    
    render(conn, :extension, 
      api_endpoint: api_endpoint,
      layout: false  # Don't use the default layout with LiveView stuff
    )
  end

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
