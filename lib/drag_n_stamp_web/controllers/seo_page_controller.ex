defmodule DragNStampWeb.SeoPageController do
  use DragNStampWeb, :controller

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.{ChapterParser, PagePath, StaticPageRenderer, VideoMetadata}

  @site_name Application.compile_env(:drag_n_stamp, :seo_site_name, "StampBot")
  @fetch_metadata? Application.compile_env(:drag_n_stamp, :seo_fetch_metadata, true)

  def show(conn, %{"filename" => filename}) do
    with {:ok, id} <- extract_id(filename),
         %Timestamp{} = timestamp <- Repo.get(Timestamp, id) do
      render_page(conn, timestamp)
    else
      _ -> send_not_found(conn)
    end
  end

  defp render_page(conn, %Timestamp{} = timestamp) do
    enriched = maybe_enrich(timestamp)

    chapters = ChapterParser.from_timestamp(enriched)
    endpoint = Phoenix.Controller.endpoint_module(conn)
    base_url = endpoint.url() |> String.trim_trailing("/")

    canonical_path = PagePath.page_path(enriched)
    canonical_url = base_url <> canonical_path

    html =
      StaticPageRenderer.render(enriched, %{
        chapters: chapters,
        base_url: base_url,
        page_path: canonical_path,
        canonical_url: canonical_url,
        feed_url: base_url <> "/feed",
        site_name: @site_name
      })

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(:ok, html)
  end

  defp extract_id(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.split("-", parts: 2)
    |> case do
      [id_part | _] ->
        case Integer.parse(id_part) do
          {id, ""} -> {:ok, id}
          _ -> :error
        end

      _ -> :error
    end
  end

  defp extract_id(_), do: :error

  defp send_not_found(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(:not_found, "SEO page not found")
  end

  defp maybe_enrich(timestamp) do
    if @fetch_metadata? do
      case VideoMetadata.ensure_metadata(timestamp) do
        {:ok, updated} -> updated
        {:error, _reason} -> timestamp
      end
    else
      timestamp
    end
  end
end
