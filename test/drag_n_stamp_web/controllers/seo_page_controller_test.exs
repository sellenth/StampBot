defmodule DragNStampWeb.SeoPageControllerTest do
  use DragNStampWeb.ConnCase, async: true

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.PagePath

  describe "GET /submissions/:filename" do
    test "renders submission page when timestamp exists", %{conn: conn} do
      timestamp =
        insert_timestamp(%{
          url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          channel_name: "Test Channel",
          content: "00:00 Intro\n00:10 Topic",
          video_title: "Example Video",
          distilled_content: "00:00 Intro\n00:10 Topic"
        })

      filename = PagePath.filename(timestamp)

      conn = get(conn, "/submissions/#{filename}")

      assert html_response(conn, 200) =~ "Example Video"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "returns 404 for unknown timestamp", %{conn: conn} do
      conn = get(conn, "/submissions/99999-missing.html")

      assert response(conn, 404) =~ "Submission page not found"
    end

    test "renders a precise stored failure instead of an empty timestamp section", %{conn: conn} do
      timestamp =
        insert_timestamp(%{
          url: "https://www.youtube.com/watch?v=failed12345",
          channel_name: "Test Channel",
          processing_status: :failed,
          processing_error:
            "[captions_fallback_failed] The server couldn't reach YouTube's caption service. (length=59m)"
        })

      conn = get(conn, PagePath.page_path(timestamp))
      html = html_response(conn, 200)

      assert html =~ "Timestamp Generation Failed"
      assert html =~ "The server couldn&#39;t reach YouTube&#39;s caption service. (length=59m)"
      assert html =~ "not scheduled an automatic retry"
      refute html =~ "<h2>Generated Timestamps</h2>"
    end
  end

  describe "GET /seo/:filename" do
    test "temporarily redirects to submissions", %{conn: conn} do
      filename = "123-example.html"
      conn = get(conn, "/seo/#{filename}")

      assert redirected_to(conn, 302) == "/submissions/#{filename}"
    end
  end

  defp insert_timestamp(attrs) do
    %Timestamp{}
    |> Timestamp.changeset(attrs)
    |> Repo.insert!()
  end
end
