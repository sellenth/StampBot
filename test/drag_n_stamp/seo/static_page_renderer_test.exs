defmodule DragNStamp.SEO.StaticPageRendererTest do
  use ExUnit.Case, async: true

  alias DragNStamp.SEO.StaticPageRenderer
  alias DragNStamp.Timestamp

  test "untrusted names and script markers remain inert and round-trip inside JSON-LD" do
    marker =
      "</ScRiPt><script id=\"injected\">window.injected=true</script><!--<script>\u2028\u2029 & names"

    timestamp = %Timestamp{
      id: 1,
      url: "https://www.youtube.com/watch?v=abc123xyz89",
      video_title: marker,
      video_description: marker,
      channel_name: marker,
      submitter_username: marker,
      content: "0:00 " <> marker,
      distilled_content: "0:00 " <> marker,
      processing_status: :ready
    }

    html = StaticPageRenderer.render(timestamp, %{site_name: marker})
    tree = Floki.parse_document!(html)
    assert [{"script", [{"type", "application/ld+json"}], [encoded]}] = Floki.find(tree, "script")
    assert Floki.find(tree, "#injected") == []
    assert String.contains?(encoded, "\\u003C")
    refute String.contains?(encoded, "<")
    refute String.contains?(encoded, "\u2028")
    refute String.contains?(encoded, "\u2029")

    decoded = Jason.decode!(encoded)
    assert decoded["name"] == marker
    assert decoded["description"] == marker
    assert decoded["author"]["name"] == marker
    assert decoded["publisher"]["name"] == marker
    assert [%{"name" => ^marker}] = Enum.map(decoded["hasPart"], &Map.take(&1, ["name"]))
  end
end
