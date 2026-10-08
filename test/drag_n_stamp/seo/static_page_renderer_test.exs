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

  defp chapters_content(count) do
    Enum.map_join(0..(count - 1), "\n", fn i -> "#{i}:00 Topic number #{i}" end)
  end

  defp ready_timestamp(content) do
    %Timestamp{
      id: 2,
      url: "https://www.youtube.com/watch?v=abc123xyz89",
      video_title: "A video",
      video_description: "Creator description #hashtag",
      content: content,
      distilled_content: content,
      processing_status: :ready
    }
  end

  test "does not republish the creator description or duplicate the raw output" do
    html = StaticPageRenderer.render(ready_timestamp(chapters_content(6)))

    refute html =~ "Creator description"
    refute html =~ "Original Output"
    refute html =~ "Unprocessed Timestamp Content"
    assert html =~ "Topic number 5"
  end

  test "indexes pages with enough chapters and noindexes thin or failed ones" do
    rich = ready_timestamp(chapters_content(6))
    thin = ready_timestamp(chapters_content(2))
    failed = %{rich | processing_status: :failed}

    assert StaticPageRenderer.render(rich) =~ ~s(content="index,follow")
    assert StaticPageRenderer.render(thin) =~ ~s(content="noindex,follow")
    assert StaticPageRenderer.render(failed) =~ ~s(content="noindex,follow")
  end
end
