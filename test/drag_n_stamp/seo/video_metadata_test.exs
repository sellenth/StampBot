defmodule DragNStamp.SEO.VideoMetadataTest do
  use ExUnit.Case, async: true

  alias DragNStamp.SEO.VideoMetadata

  describe "parse_duration/1" do
    test "parses hours minutes seconds" do
      assert VideoMetadata.parse_duration("PT1H2M3S") == 3723
    end

    test "parses minutes seconds" do
      assert VideoMetadata.parse_duration("PT7M5S") == 425
    end

    test "parses seconds only" do
      assert VideoMetadata.parse_duration("PT45S") == 45
    end

    test "returns nil for invalid durations" do
      assert VideoMetadata.parse_duration("invalid") == nil
      assert VideoMetadata.parse_duration(nil) == nil
    end
  end

  describe "extract_video_id/1" do
    test "extracts id from watch url" do
      assert VideoMetadata.extract_video_id("https://www.youtube.com/watch?v=abc123") ==
               {:ok, "abc123"}
    end

    test "extracts id from short url" do
      assert VideoMetadata.extract_video_id("https://youtu.be/xyz789") == {:ok, "xyz789"}
    end

    test "rejects invalid url" do
      assert {:error, :invalid_url} = VideoMetadata.extract_video_id("https://example.com")
    end
  end
end
