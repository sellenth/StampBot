defmodule DragNStampWeb.SeoPageControllerTest do
  use DragNStampWeb.ConnCase, async: true

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.PagePath

  describe "GET /seo/:filename" do
    test "renders SEO page when timestamp exists", %{conn: conn} do
      timestamp = insert_timestamp(%{
        url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        channel_name: "Test Channel",
        content: "00:00 Intro\n00:10 Topic",
        video_title: "Example Video",
        distilled_content: "00:00 Intro\n00:10 Topic"
      })

      filename = PagePath.filename(timestamp)

      conn = get(conn, "/seo/#{filename}")

      assert html_response(conn, 200) =~ "Example Video"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "returns 404 for unknown timestamp", %{conn: conn} do
      conn = get(conn, "/seo/99999-missing.html")

      assert response(conn, 404) =~ "SEO page not found"
    end
  end

  defp insert_timestamp(attrs) do
    %Timestamp{}
    |> Timestamp.changeset(attrs)
    |> Repo.insert!()
  end
end
