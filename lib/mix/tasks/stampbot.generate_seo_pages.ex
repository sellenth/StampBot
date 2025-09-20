defmodule Mix.Tasks.Stampbot.GenerateSeoPages do
  @moduledoc """
  Generates per-timestamp static pages under `priv/static/seo/`.

  The task pulls the latest timestamp rows, derives chapter data, injects
  metadata, and writes enriched static HTML files ready for deployment.
  """

  use Mix.Task

  import Ecto.Query

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.{ChapterParser, StaticPageRenderer, VideoMetadata}

  @shortdoc "Generate static SEO pages for timestamps"

  @switches [limit: :integer, output: :string, base_url: :string, site_name: :string]
  @aliases [l: :limit, o: :output, b: :base_url, s: :site_name]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    output_dir = build_output_dir(opts)
    File.mkdir_p!(output_dir)

    base_url = build_base_url(opts)
    site_name = Keyword.get(opts, :site_name, "StampBot")

    Timestamp
    |> order_by(desc: :inserted_at)
    |> maybe_limit(opts)
    |> Repo.all()
    |> Enum.map(&maybe_enrich/1)
    |> Enum.map(&persist_page(&1, output_dir, base_url: base_url, site_name: site_name))
    |> Enum.each(&report_page/1)
  end

  defp persist_page({:ok, %Timestamp{} = timestamp}, output_dir, extra_opts) do
    do_persist_page(timestamp, output_dir, extra_opts)
  end

  defp persist_page({:error, %Timestamp{} = timestamp}, output_dir, extra_opts) do
    do_persist_page(timestamp, output_dir, extra_opts)
  end

  defp do_persist_page(%Timestamp{} = timestamp, output_dir, extra_opts) do
    slug = slugify(timestamp)
    filename = "#{timestamp.id}-#{slug}.html"
    file_path = Path.join(output_dir, filename)
    page_path = "/seo/#{filename}"

    chapters = ChapterParser.from_timestamp(timestamp)
    video_id = timestamp.video_id || extract_video_id(timestamp.url)
    thumbnail_url = timestamp.video_thumbnail_url || default_thumbnail(video_id)

    video_title = timestamp.video_title || derive_title(timestamp, chapters)
    summary = timestamp.video_description || derive_summary(timestamp, chapters)
    published_at = timestamp.video_published_at || timestamp.inserted_at
    duration = timestamp.video_duration_seconds

    base_url = Keyword.fetch!(extra_opts, :base_url)
    site_name = Keyword.fetch!(extra_opts, :site_name)
    canonical_url = base_url <> page_path

    html =
      StaticPageRenderer.render(timestamp, %{
        video_title: video_title,
        summary: summary,
        chapters: chapters,
        canonical_url: canonical_url,
        page_path: page_path,
        base_url: base_url,
        thumbnail_url: thumbnail_url,
        video_id: video_id,
        site_name: site_name,
        video_duration: duration,
        published_at: published_at,
        channel_name: timestamp.channel_name
      })

    File.write!(file_path, html)

    {timestamp.id, file_path}
  end

  defp report_page({id, file_path}) do
    Mix.shell().info("Generated static page for ##{id} -> #{relative(file_path)}")
  end

  defp build_output_dir(opts) do
    root = File.cwd!()
    default = Path.join(root, "priv/static/seo")

    case Keyword.get(opts, :output) do
      nil -> default
      path -> Path.expand(path, root)
    end
  end

  defp build_base_url(opts) do
    opts
    |> Keyword.get(:base_url, "https://stamp-bot.com")
    |> String.trim_trailing("/")
  end

  defp maybe_limit(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      limit when is_integer(limit) and limit > 0 -> limit(query, ^limit)
      _ -> query
    end
  end

  defp slugify(%Timestamp{} = timestamp) do
    source =
      cond do
        is_binary(timestamp.video_title) and timestamp.video_title != "" ->
          timestamp.video_title

        is_binary(timestamp.channel_name) and timestamp.channel_name != "" ->
          timestamp.channel_name

        is_binary(timestamp.distilled_content) and timestamp.distilled_content != "" ->
          timestamp.distilled_content

        is_binary(timestamp.content) ->
          timestamp.content

        true ->
          "timestamp"
      end

    source
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "timestamp"
      slug -> String.slice(slug, 0, 60)
    end
  end

  defp relative(path) do
    root = File.cwd!()

    case String.replace_prefix(path, root <> "/", "") do
      ^path -> path
      relative_path -> relative_path
    end
  end

  defp derive_title(_timestamp, [first | _]) do
    first.title
    |> String.trim()
    |> String.slice(0, 70)
  end

  defp derive_title(%Timestamp{channel_name: channel} = timestamp, _chapters) do
    cond do
      is_binary(channel) and channel != "" -> "#{channel} – StampBot Chapters"
      is_binary(timestamp.distilled_content) -> String.slice(timestamp.distilled_content, 0, 70)
      is_binary(timestamp.content) -> String.slice(timestamp.content, 0, 70)
      true -> "StampBot Timestamp"
    end
  end

  defp derive_summary(_timestamp, chapters) when chapters != [] do
    chapters
    |> Enum.take(3)
    |> Enum.map(& &1.title)
    |> Enum.join(" • ")
    |> String.slice(0, 160)
  end

  defp derive_summary(%Timestamp{} = timestamp, _chapters) do
    cond do
      is_binary(timestamp.distilled_content) -> String.slice(timestamp.distilled_content, 0, 160)
      is_binary(timestamp.content) -> String.slice(timestamp.content, 0, 160)
      true -> "Generated with StampBot"
    end
  end

  defp extract_video_id(url) do
    case VideoMetadata.extract_video_id(url) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp default_thumbnail(nil), do: nil
  defp default_thumbnail(video_id), do: "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg"

  defp maybe_enrich(%Timestamp{} = timestamp) do
    case VideoMetadata.ensure_metadata(timestamp) do
      {:ok, updated} -> {:ok, updated}
      {:error, _reason} -> {:error, timestamp}
    end
  end
end
