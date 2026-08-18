defmodule DragNStampWeb.HomeLiveTest do
  use DragNStampWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DragNStamp.{Repo, Timestamp}

  test "home page renders submit and feed in order", %{conn: conn} do
    insert_timestamp(%{
      submitter_username: "alice",
      channel_name: "Alpha Channel",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready,
      estimated_cost_usd: Decimal.new("0.012345")
    })

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#url-form")
    assert has_element?(view, "#feed")
    refute has_element?(view, "#leaderboard")
    assert html =~ "Est. total: $0.0123"

    assert html_index(html, ~s(id="url-form")) < html_index(html, ~s(id="feed"))
  end

  test "valid submission stays on home and shows loading state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#url-form", %{
        url: "https://www.youtube.com/watch?v=abc123xyz89",
        username: "alice"
      })
      |> render_submit()

    assert html =~ "Generating..."
    assert has_element?(view, "#feed")
    refute has_element?(view, "#leaderboard")
  end

  defp insert_timestamp(attrs) do
    defaults = %{
      url: "https://www.youtube.com/watch?v=#{System.unique_integer([:positive])}",
      channel_name: "Channel",
      submitter_username: "anonymous",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready,
      youtube_comment_status: :not_attempted
    }

    %Timestamp{}
    |> Timestamp.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp html_index(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> raise "expected to find #{inspect(needle)} in rendered HTML"
    end
  end
end
