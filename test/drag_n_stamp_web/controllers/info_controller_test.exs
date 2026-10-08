defmodule DragNStampWeb.InfoControllerTest do
  use DragNStampWeb.ConnCase, async: true

  for {path, heading} <- [
        {"/how-it-works", "How StampBot works"},
        {"/youtube-chapters-guide", "A guide to YouTube chapters"},
        {"/about", "About StampBot"}
      ] do
    test "GET #{path} renders original content", %{conn: conn} do
      html = html_response(get(conn, unquote(path)), 200)
      assert html =~ unquote(heading)
      assert html =~ ~s(href="/youtube-chapters-guide")
    end
  end

  test "sitemap lists the content pages", %{conn: conn} do
    xml = response(get(conn, "/sitemap.xml"), 200)

    for path <- ["/how-it-works", "/youtube-chapters-guide", "/about"] do
      assert xml =~ "https://stamp-bot.com#{path}</loc>"
    end
  end
end
