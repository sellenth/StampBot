defmodule DragNStamp.SEO.StaticPageRenderer do
  @moduledoc """
  Produces static HTML for timestamp records with enriched SEO metadata.
  """

  alias DragNStamp.Timestamp
  alias DragNStamp.SEO.ChapterParser

  @default_base_url "https://stamp-bot.com"
  @default_site_name "StampBot"

  @spec render(Timestamp.t(), map()) :: String.t()
  def render(%Timestamp{} = timestamp, opts \\ %{}) do
    base_url = Map.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")
    page_path = Map.get(opts, :page_path, "")
    canonical_url = Map.get(opts, :canonical_url) || build_canonical(base_url, page_path)
    video_url = Map.get(opts, :video_url, timestamp.url)

    chapters = Map.get(opts, :chapters) || ChapterParser.from_timestamp(timestamp)

    video_title =
      Map.get(opts, :video_title) ||
        timestamp.video_title ||
        default_title(timestamp, chapters)

    summary =
      Map.get(opts, :summary) ||
        timestamp.video_description ||
        default_summary(timestamp, chapters)

    seo_summary = truncate_summary(summary, 150)

    site_name = Map.get(opts, :site_name, @default_site_name)
    video_id = Map.get(opts, :video_id) || extract_video_id(video_url)

    thumbnail_url =
      Map.get(opts, :thumbnail_url) || timestamp.video_thumbnail_url ||
        default_thumbnail(video_id)

    published_at =
      Map.get(opts, :published_at) || timestamp.video_published_at || timestamp.inserted_at

    duration = Map.get(opts, :video_duration) || timestamp.video_duration_seconds
    channel_meta = build_channel_meta(timestamp)
    channel_name = Map.get(opts, :channel_name) || timestamp.channel_name
    feed_url = Map.get(opts, :feed_url, base_url <> "/feed")

    structured_data =
      build_json_ld(%{
        name: video_title,
        description: summary,
        video_url: video_url,
        canonical_url: canonical_url,
        thumbnail_url: thumbnail_url,
        published_at: published_at,
        duration: duration,
        chapters: chapters,
        site_name: site_name,
        video_id: video_id,
        channel_name: channel_name
      })

    chapter_section = build_content_body(chapters, timestamp, video_url)
    hero_section = build_hero(thumbnail_url, video_url, video_title)
      canonical_tag = canonical_link_tag(canonical_url)

    """
    <!DOCTYPE html>
    <html lang=\"en\">
    <head>
      <meta charset=\"utf-8\" />
      <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
      <title>#{html_escape(video_title)} | #{html_escape(site_name)}</title>
      <meta name=\"description\" content=\"#{html_escape(seo_summary)}\" />
      <meta name=\"robots\" content=\"index,follow\" />
      #{canonical_tag}
      #{meta_tags(video_title, seo_summary, canonical_url, thumbnail_url, site_name)}
      <script type=\"application/ld+json\">#{structured_data}</script>
      <style>
        :root {
          --bg-primary: #ffffff;
          --bg-secondary: #f8f8f8;
          --bg-tertiary: #f0f0f0;
          --text-primary: #0b0b0b;
          --text-secondary: #4b5563;
          --text-muted: #6b7280;
          --border-color: #e5e7eb;
          --accent-color: #3b82f6;
          --btn-primary-bg: #3b82f6;
          --btn-primary-color: #ffffff;
          --btn-primary-hover: #2563eb;
          --shadow-light: rgba(0, 0, 0, 0.1);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg-primary: #0b0f14;
            --bg-secondary: #12161c;
            --bg-tertiary: #1b222c;
            --text-primary: #e5e7eb;
            --text-secondary: #cbd5e1;
            --text-muted: #94a3b8;
            --border-color: #2a3340;
            --accent-color: #60a5fa;
            --btn-primary-bg: #60a5fa;
            --btn-primary-color: #0b0f14;
            --btn-primary-hover: #3b82f6;
            --shadow-light: rgba(0, 0, 0, 0.3);
          }
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
          margin: 0;
          padding: 0;
          background: var(--bg-primary);
          color: var(--text-primary);
          line-height: 1.6;
          transition: background-color 0.3s ease, color 0.3s ease;
        }
        main { max-width: 960px; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; }
        header { text-align: center; margin-bottom: 2.5rem; }
        header h1 {
          margin: 0 0 0.75rem;
          font-size: 2.5rem;
          line-height: 1.1;
          font-weight: 700;
          color: var(--text-primary);
        }
        header p {
          margin: 0 auto;
          max-width: 720px;
          color: var(--text-secondary);
          font-size: 1.05rem;
        }
        .page-nav {
          display: flex;
          justify-content: center;
          margin-bottom: 1.5rem;
        }
        .page-nav a {
          display: inline-flex;
          align-items: center;
          gap: 0.35rem;
          padding: 0.5rem 1rem;
          background: var(--btn-primary-bg);
          color: var(--btn-primary-color);
          text-decoration: none;
          font-weight: 600;
          border-radius: 0.5rem;
          border: 1px solid var(--btn-primary-bg);
          transition: all 0.2s ease;
          box-shadow: 0 1px 3px var(--shadow-light);
        }
        .page-nav a:hover {
          background: var(--btn-primary-hover);
          border-color: var(--btn-primary-hover);
          transform: translateY(-1px);
          box-shadow: 0 2px 6px var(--shadow-light);
        }
        .hero {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 1rem;
          margin-bottom: 2rem;
        }
        .hero img {
          border-radius: 0.75rem;
          box-shadow: 0 10px 25px var(--shadow-light);
          width: 100%;
          max-width: 720px;
          height: auto;
          border: 1px solid var(--border-color);
        }
        .hero a {
          display: inline-flex;
          align-items: center;
          gap: 0.5rem;
          padding: 0.75rem 1.5rem;
          border-radius: 0.5rem;
          background: var(--btn-primary-bg);
          color: var(--btn-primary-color);
          text-decoration: none;
          font-weight: 600;
          border: 1px solid var(--btn-primary-bg);
          transition: all 0.2s ease;
          box-shadow: 0 2px 8px var(--shadow-light);
        }
        .hero a:hover {
          background: var(--btn-primary-hover);
          border-color: var(--btn-primary-hover);
          transform: translateY(-1px);
          box-shadow: 0 4px 12px var(--shadow-light);
        }
        section {
          background: var(--bg-secondary);
          border-radius: 0.75rem;
          padding: 1.75rem;
          margin-bottom: 2rem;
          border: 1px solid var(--border-color);
          box-shadow: 0 2px 8px var(--shadow-light);
        }
        section h2 {
          margin-top: 0;
          font-size: 1.5rem;
          font-weight: 600;
          color: var(--text-primary);
        }
        ul { padding-left: 1.25rem; list-style-type: none; }
        li {
          margin-bottom: 0.75rem;
          color: var(--text-secondary);
        }
        li a {
          color: var(--accent-color);
          font-weight: 600;
          text-decoration: none;
          transition: color 0.2s ease;
        }
        li a:hover {
          color: var(--btn-primary-hover);
          text-decoration: underline;
        }
        pre {
          background: var(--bg-primary);
          border: 1px solid var(--border-color);
          border-radius: 0.5rem;
          padding: 1rem;
          overflow-x: auto;
          color: var(--text-primary);
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace;
          font-size: 0.9rem;
          line-height: 1.4;
        }
        .channel-meta {
          display: flex;
          gap: 1rem;
          flex-wrap: wrap;
          color: var(--text-muted);
          margin-top: 1rem;
          font-size: 0.95rem;
          align-items: center;
          justify-content: center;
        }
        .channel-meta .separator {
          color: var(--text-muted);
          opacity: 0.6;
        }
        footer {
          text-align: center;
          color: var(--text-muted);
          font-size: 0.85rem;
          margin-top: 3rem;
          padding-top: 2rem;
          border-top: 1px solid var(--border-color);
        }
        footer a {
          color: var(--accent-color);
          text-decoration: none;
        }
        footer a:hover {
          text-decoration: underline;
        }
        @media (max-width: 640px) {
          main { padding: 1.5rem 1rem 2rem; }
          header h1 { font-size: 1.9rem; }
          section { padding: 1.25rem; }
          .hero img { border-radius: 0.5rem; }
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <nav class="page-nav">
            <a href="#{html_escape(feed_url)}">← Back to Timestamp Feed</a>
          </nav>
          <h1>#{html_escape(video_title)}</h1>
          <p>#{html_escape(summary)}</p>
          #{channel_meta}
        </header>
        #{hero_section}
        #{chapter_section}
        #{raw_section(timestamp)}
        #{submission_content_section(timestamp)}
        <footer>
          Generated by #{html_escape(site_name)} • <a href=\"#{html_escape(base_url)}\" style=\"color:#38bdf8;text-decoration:none;\">Visit #{html_escape(site_name)}</a>
        </footer>
      </main>
    </body>
    </html>
    """
  end

  defp build_canonical(_, ""), do: nil
  defp build_canonical(base_url, page_path), do: base_url <> page_path

  defp canonical_link_tag(nil), do: ""
  defp canonical_link_tag(url), do: "<link rel=\"canonical\" href=\"#{html_escape(url)}\" />"

  defp meta_tags(title, description, canonical_url, thumbnail_url, site_name) do
    og_image =
      if thumbnail_url,
        do: "  <meta property=\"og:image\" content=\"#{html_escape(thumbnail_url)}\" />",
        else: nil

    [
      "  <meta property=\"og:type\" content=\"video.other\" />",
      "  <meta property=\"og:title\" content=\"#{html_escape(title)}\" />",
      "  <meta property=\"og:description\" content=\"#{html_escape(description)}\" />",
      if(canonical_url,
        do: "  <meta property=\"og:url\" content=\"#{html_escape(canonical_url)}\" />",
        else: nil
      ),
      og_image,
      "  <meta name=\"twitter:card\" content=\"summary_large_image\" />",
      "  <meta name=\"twitter:title\" content=\"#{html_escape(title)}\" />",
      "  <meta name=\"twitter:description\" content=\"#{html_escape(description)}\" />",
      if(thumbnail_url,
        do: "  <meta name=\"twitter:image\" content=\"#{html_escape(thumbnail_url)}\" />",
        else: nil
      ),
      "  <meta property=\"og:site_name\" content=\"#{html_escape(site_name)}\" />"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp truncate_summary(nil, _limit), do: ""

  defp truncate_summary(summary, limit) when is_binary(summary) and is_integer(limit) and limit > 0 do
    trimmed =
      summary
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    cond do
      trimmed == "" ->
        ""

      String.length(trimmed) <= limit ->
        trimmed

      true ->
        truncated =
          trimmed
          |> String.slice(0, limit)
          |> String.trim_trailing()

        (if truncated == "", do: String.slice(trimmed, 0, limit), else: truncated) <> "…"
    end
  end

  defp truncate_summary(summary, _limit) when is_binary(summary) do
    summary |> String.trim()
  end

  defp truncate_summary(_, _limit), do: ""

  defp build_content_body([], timestamp, _video_url) do
    """
    <section>
      <h2>Generated Timestamps</h2>
      <pre>#{html_escape(timestamp.distilled_content || timestamp.content || "")}</pre>
    </section>
    """
  end

  defp build_content_body(chapters, _timestamp, video_url) do
    items =
      chapters
      |> Enum.map(fn chapter ->
        label = html_escape(chapter.title)
        timecode = html_escape(chapter.timecode || format_timestamp(chapter.starts_at))
        link = chapter_link(video_url, chapter.starts_at)

        case link do
          nil ->
            "<li><strong>#{timecode}</strong> #{label}</li>"

          url ->
            "<li><a href=\"#{html_escape(url)}\"><strong>#{timecode}</strong> #{label}</a></li>"
        end
      end)
      |> Enum.join("\n")

    """
    <section>
      <h2>Video Chapters</h2>
      <ul>
      #{items}
      </ul>
    </section>
    """
  end

  defp build_hero(nil, _video_url, _video_title), do: ""

  defp build_hero(thumbnail_url, video_url, video_title) do
    button =
      if video_url do
        "<a href=\"#{html_escape(video_url)}\" target=\"_blank\" rel=\"noopener noreferrer\">▶ Watch on YouTube</a>"
      else
        ""
      end

    """
    <div class=\"hero\">
      <img src=\"#{html_escape(thumbnail_url)}\" alt=\"Thumbnail for #{html_escape(video_title)}\" loading=\"lazy\" />
      #{button}
    </div>
    """
  end

  defp raw_section(timestamp) do
    raw = timestamp.distilled_content || timestamp.content || ""

    if String.trim(raw) == "" do
      ""
    else
      """
      <section>
        <h2>Original Output</h2>
        <pre>#{html_escape(raw)}</pre>
      </section>
      """
    end
  end

  defp submission_content_section(timestamp) do
    content = timestamp.content || ""

    if String.trim(content) == "" do
      ""
    else
      """
      <section>
        <h2>Unprocessed Timestamp Content</h2>
        <pre>#{html_escape(content)}</pre>
      </section>
      """
    end
  end

  defp channel_tag(%Timestamp{channel_name: channel}) when channel in [nil, ""], do: ""

  defp channel_tag(%Timestamp{channel_name: channel}) do
    channel = html_escape(channel)
    "<span>Channel: <strong>#{channel}</strong></span>"
  end

  defp submitted_tag(%Timestamp{submitter_username: user}) when user in [nil, ""], do: ""

  defp submitted_tag(%Timestamp{submitter_username: user}) do
    user = html_escape(user)
    "<span>Generated by #{user}</span>"
  end

  defp duration_tag(%Timestamp{video_duration_seconds: nil}), do: ""

  defp duration_tag(%Timestamp{video_duration_seconds: seconds})
       when is_integer(seconds) and seconds > 0 do
    "<span>Duration: #{html_escape(format_human_duration(seconds))}</span>"
  end

  defp duration_tag(_), do: ""

  defp published_tag(%Timestamp{video_published_at: nil}), do: ""

  defp published_tag(%Timestamp{video_published_at: datetime}) do
    case format_published_at(datetime) do
      nil -> ""
      formatted -> "<span>Published #{html_escape(formatted)}</span>"
    end
  end

  defp build_channel_meta(timestamp) do
    tags =
      [
        channel_tag(timestamp),
        submitted_tag(timestamp),
        duration_tag(timestamp),
        published_tag(timestamp)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case tags do
      [] ->
        ""

      _ ->
        "<div class=\"channel-meta\">" <>
          Enum.join(tags, "<span class=\"separator\">•</span>") <> "</div>"
    end
  end

  defp build_json_ld(assigns) do
    %{
      "@context" => "https://schema.org",
      "@type" => "VideoObject",
      "name" => assigns.name,
      "description" => assigns.description,
      "thumbnailUrl" => List.wrap(assigns.thumbnail_url) |> Enum.reject(&is_nil/1),
      "contentUrl" => assigns.video_url,
      "embedUrl" => assigns.video_url,
      "uploadDate" => format_datetime(assigns.published_at),
      "publisher" => publisher(assigns.site_name),
      "hasPart" => build_clips(assigns.chapters, assigns.video_url)
    }
    |> maybe_put("url", assigns.canonical_url)
    |> maybe_put("videoId", assigns.video_id)
    |> maybe_put("duration", format_duration(assigns.duration))
    |> maybe_put("author", build_author(assigns.channel_name))
    |> Jason.encode!()
  end

  defp publisher(site_name) do
    %{
      "@type" => "Organization",
      "name" => site_name
    }
  end

  defp build_author(nil), do: nil

  defp build_author(name) do
    %{
      "@type" => "Organization",
      "name" => name
    }
  end

  defp build_clips([], _video_url), do: []

  defp build_clips(chapters, video_url) do
    Enum.map(chapters, fn chapter ->
      %{"@type" => "Clip", "name" => chapter.title}
      |> maybe_put("startOffset", chapter.starts_at)
      |> maybe_put("url", chapter_link(video_url, chapter.starts_at))
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp format_datetime(_), do: nil

  defp format_duration(nil), do: nil

  defp format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    parts = []
    parts = maybe_duration_part(parts, hours, "H")
    parts = maybe_duration_part(parts, minutes, "M")
    parts = maybe_duration_part(parts, secs, "S")

    if parts == [] do
      "PT0S"
    else
      "PT" <> Enum.join(parts, "")
    end
  end

  defp format_duration(_), do: nil

  defp maybe_duration_part(parts, value, _unit) when value in [nil, 0], do: parts

  defp maybe_duration_part(parts, value, unit) when is_integer(value) and value > 0 do
    parts ++ ["#{value}#{unit}"]
  end

  defp chapter_link(_, nil), do: nil
  defp chapter_link(nil, _seconds), do: nil

  defp chapter_link(video_url, seconds)
       when is_binary(video_url) and is_integer(seconds) and seconds >= 0 do
    uri =
      video_url
      |> URI.parse()
      |> put_time_param(seconds)

    URI.to_string(uri)
  end

  defp chapter_link(_, _), do: nil

  defp put_time_param(%URI{} = uri, seconds) do
    time_param = Integer.to_string(seconds)

    updated_query =
      uri.query
      |> decode_query()
      |> Map.put("t", time_param)
      |> URI.encode_query()

    %{uri | query: updated_query}
  end

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    try do
      URI.decode_query(query)
    rescue
      ArgumentError -> %{}
    end
  end

  defp default_title(timestamp, chapters) do
    cond do
      chapters != [] ->
        chapters |> List.first() |> Map.get(:title) |> truncate(70)

      is_binary(timestamp.channel_name) and timestamp.channel_name != "" ->
        "#{timestamp.channel_name} – StampBot Chapter Highlights"

      true ->
        truncate(timestamp.distilled_content || timestamp.content || "StampBot Timestamp", 70)
    end
  end

  defp default_summary(timestamp, chapters) do
    cond do
      chapters != [] ->
        chapters
        |> Enum.take(3)
        |> Enum.map(& &1.title)
        |> Enum.join(" • ")
        |> truncate(160)

      true ->
        truncate(
          timestamp.distilled_content || timestamp.content || "Generated with StampBot",
          160
        )
    end
  end

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp html_escape(nil), do: ""

  defp html_escape(binary) when is_binary(binary) do
    binary
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html_escape(other), do: to_string(other) |> html_escape()

  defp format_timestamp(nil), do: ""

  defp format_timestamp(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, secs]) |> to_string()
      true -> :io_lib.format("~2..0B:~2..0B", [minutes, secs]) |> to_string()
    end
  end

  defp format_timestamp(_), do: ""

  defp format_human_duration(seconds) when seconds < 60 do
    "#{seconds}s"
  end

  defp format_human_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    [
      if(hours > 0, do: "#{hours}h"),
      if(minutes > 0, do: "#{minutes}m"),
      if(secs > 0 and hours == 0 and minutes == 0, do: "#{secs}s")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "#{secs}s"
      result -> result
    end
  end

  defp format_published_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")

  defp format_published_at(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> format_published_at(dt)
      _ -> Calendar.strftime(NaiveDateTime.to_date(ndt), "%b %d, %Y")
    end
  end

  defp format_published_at(_), do: nil

  defp extract_video_id(nil), do: nil

  defp extract_video_id(video_url) when is_binary(video_url) do
    cond do
      String.contains?(video_url, "watch?v=") ->
        case Regex.run(~r/[?&]v=([^&]+)/, video_url) do
          [_, id] -> id
          _ -> nil
        end

      String.contains?(video_url, "youtu.be/") ->
        case Regex.run(~r/youtu\.be\/([^?&]+)/, video_url) do
          [_, id] -> id
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp default_thumbnail(nil), do: nil
  defp default_thumbnail(video_id), do: "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg"
end
