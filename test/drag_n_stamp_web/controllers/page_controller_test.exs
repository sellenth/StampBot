defmodule DragNStampWeb.PageControllerTest do
  use DragNStampWeb.ConnCase

  test "GET / renders the merged home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Generate Timestamps"
    assert html =~ ~s(id="feed")
  end

  test "GET /feed redirects to the feed anchor", %{conn: conn} do
    conn = get(conn, ~p"/feed")
    assert redirected_to(conn) == "/#feed"
  end

  test "GET /leaderboard renders the leaderboard page", %{conn: conn} do
    conn = get(conn, ~p"/leaderboard")
    assert html_response(conn, 200) =~ "Top contributors and community statistics"
  end
end
