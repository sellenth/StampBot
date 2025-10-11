defmodule DragNStamp.SEO.PagePathTest do
  use ExUnit.Case, async: true

  alias DragNStamp.{Timestamp}
  alias DragNStamp.SEO.PagePath

  test "prefers video title" do
    ts = struct(Timestamp, %{id: 123, video_title: "Amazing Video Review!"})
    assert PagePath.slug(ts) == "amazing-video-review"
  end

  test "falls back to channel name" do
    ts = struct(Timestamp, %{id: 456, channel_name: "My Cool Channel"})
    assert PagePath.slug(ts) == "my-cool-channel"
  end

  test "provides filename and page path" do
    ts = struct(Timestamp, %{id: 42, video_title: "Sample"})
    assert PagePath.filename(ts) == "42-sample.html"
    assert PagePath.page_path(ts) == "/submissions/42-sample.html"
  end

  test "handles missing id" do
    ts = struct(Timestamp, %{id: nil, video_title: "Sample"})
    assert PagePath.filename(ts) == "tmp-sample.html"
  end

  test "builds full url" do
    ts = struct(Timestamp, %{id: 99, video_title: "Sample"})

    assert PagePath.page_url(ts, "https://stamp-bot.com") ==
             "https://stamp-bot.com/submissions/99-sample.html"
  end
end
