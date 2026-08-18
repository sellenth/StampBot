defmodule DragNStamp.Timestamps.CaptionFallbackTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.CaptionFallback

  describe "caption_fetch_failure_reason/1" do
    test "maps downloader failures to actionable categories" do
      cases = [
        unsupported_option: :caption_downloader_outdated,
        unsupported_runtime: :caption_runtime_outdated,
        binary_unavailable: :caption_downloader_unavailable,
        cookies_invalid: :youtube_auth_failed,
        youtube_auth_required: :youtube_auth_failed,
        rate_limited: :youtube_rate_limited,
        network_error: :youtube_network_error,
        video_unavailable: :video_unavailable,
        no_subtitles: :captions_unavailable,
        unknown: :captions_fetch_failed
      ]

      for {downloader_reason, expected} <- cases do
        reason = {:yt_dlp_failed, downloader_reason, %{exit_status: 1}}
        assert CaptionFallback.caption_fetch_failure_reason(reason) == expected
      end
    end
  end

  describe "failure_message/1" do
    test "explains operational caption failures accurately" do
      assert CaptionFallback.failure_message(:caption_downloader_outdated) =~ "out of date"

      assert CaptionFallback.failure_message(:caption_runtime_outdated) =~
               "runtime is out of date"

      assert CaptionFallback.failure_message(:youtube_auth_failed) =~ "credentials"
      assert CaptionFallback.failure_message(:youtube_rate_limited) =~ "rate-limited"
      assert CaptionFallback.failure_message(:youtube_network_error) =~ "couldn't reach"
      assert CaptionFallback.failure_message(:video_unavailable) =~ "private, removed"
    end
  end
end
