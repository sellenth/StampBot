defmodule DragNStampWeb.PageControllerTest do
  use DragNStampWeb.ConnCase

  test "GET / renders the merged home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Generate Timestamps"
    assert html =~ ~s(id="feed")
  end

  test "GET /extension loads the resumable submission client", %{conn: conn} do
    html = conn |> get(~p"/extension") |> html_response(200)

    assert html =~ ~s(src="/js/submission-client.js")
    assert html =~ ~s(src="/js/extension-page.js")
    assert html =~ ~s(id="resume-updates")
    assert html =~ "After your submission is saved"
    refute html =~ "timestampsDiv.innerHTML"
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
