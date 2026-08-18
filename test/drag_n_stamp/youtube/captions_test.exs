defmodule DragNStamp.YouTube.CaptionsTest do
  use ExUnit.Case, async: true

  alias DragNStamp.YouTube.Captions

  describe "classify_ytdlp_failure/1" do
    test "identifies a downloader that does not support the configured options" do
      output = "yt-dlp: error: no such option: --js-runtimes"

      assert Captions.classify_ytdlp_failure(output) == :unsupported_option
    end

    test "identifies an unsupported JavaScript runtime" do
      output = "WARNING: Node version 20 is not supported; Node 22 or newer is required"

      assert Captions.classify_ytdlp_failure(output) == :unsupported_runtime
    end

    test "identifies invalid cookies" do
      output = "ERROR: cookie file must be in Mozilla/Netscape format"

      assert Captions.classify_ytdlp_failure(output) == :cookies_invalid
    end

    test "identifies YouTube bot authentication challenges" do
      output =
        "ERROR: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies"

      assert Captions.classify_ytdlp_failure(output) == :youtube_auth_required
    end

    test "identifies rate limits" do
      assert Captions.classify_ytdlp_failure("ERROR: HTTP Error 429: Too Many Requests") ==
               :rate_limited
    end

    test "identifies unavailable videos" do
      assert Captions.classify_ytdlp_failure("ERROR: [youtube] abc: Private video") ==
               :video_unavailable
    end

    test "identifies videos without captions" do
      assert Captions.classify_ytdlp_failure("abc has no subtitles") == :no_subtitles
    end

    test "identifies network failures" do
      output = "ERROR: Unable to download webpage: Temporary failure in name resolution"

      assert Captions.classify_ytdlp_failure(output) == :network_error
    end

    test "keeps unmatched failures explicit" do
      assert Captions.classify_ytdlp_failure("ERROR: an unexpected extractor failure") == :unknown
    end
  end
end
