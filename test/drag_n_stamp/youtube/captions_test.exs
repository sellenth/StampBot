defmodule DragNStamp.YouTube.CaptionsTest do
  use ExUnit.Case, async: true

  alias DragNStamp.YouTube.Captions

  test "anonymous human captions succeed without consulting configured cookies" do
    runner = fn args ->
      refute "--cookies" in args
      assert "--ignore-config" in args
      assert "--no-playlist" in args
      assert "--write-subs" in args
      write_captions(args)
    end

    assert {:ok, result} =
             Captions.fetch_transcript("tMu_ZaXkqeo", runner: runner, cookies_path: "/unused")

    assert [%{access_mode: "anonymous", status: :ok}] = result.context.attempts
    refute result.context.cookies_supplied
  end

  test "missing human captions fall back to anonymous automatic captions" do
    runner = fn args ->
      refute "--cookies" in args
      if "--write-auto-subs" in args, do: write_captions(args), else: {:ok, "no human captions"}
    end

    assert {:ok, result} =
             Captions.fetch_transcript("tMu_ZaXkqeo", runner: runner, cookies_path: "/unused")

    assert result.context.chosen_variant == :auto_subtitles
    assert length(result.context.attempts) == 2
  end

  test "a bot challenge switches once to authenticated extraction with both caption types" do
    runner = fn args ->
      if "--cookies" in args do
        assert "--write-subs" in args and "--write-auto-subs" in args
        write_captions(args)
      else
        {:error, {:yt_dlp_failed, :youtube_bot_challenge, %{}}}
      end
    end

    assert {:ok, result} =
             Captions.fetch_transcript("tMu_ZaXkqeo", runner: runner, cookies_path: "/fixture")

    assert [
             %{access_mode: "anonymous", status: :error},
             %{access_mode: "authenticated", status: :ok}
           ] = result.context.attempts
  end

  test "an authenticated failure is final and preserves both attempts" do
    runner = fn args ->
      category = if "--cookies" in args, do: :cookies_invalid, else: :youtube_auth_required
      {:error, {:yt_dlp_failed, category, %{}}}
    end

    assert {:error, {:yt_dlp_failed, :cookies_invalid, _}, context} =
             Captions.fetch_transcript("tMu_ZaXkqeo", runner: runner, cookies_path: "/fixture")

    assert length(context.attempts) == 2
  end

  test "missing cookies, rate limits and unavailable videos never repeat authenticated requests" do
    for category <- [:youtube_bot_challenge, :rate_limited, :video_unavailable] do
      runner = fn args ->
        refute "--cookies" in args
        {:error, {:yt_dlp_failed, category, %{}}}
      end

      cookies = if category == :youtube_bot_challenge, do: nil, else: "/unused"

      assert {:error, _, context} =
               Captions.fetch_transcript("tMu_ZaXkqeo", runner: runner, cookies_path: cookies)

      assert length(context.attempts) == 1
    end
  end

  defp write_captions(args) do
    template = args |> Enum.drop_while(&(&1 != "--output")) |> Enum.at(1)
    path = Path.join(Path.dirname(template), "tMu_ZaXkqeo.en.vtt")
    File.write!(path, "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nOpening narration.\n")
    {:ok, ""}
  end

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

      assert Captions.classify_ytdlp_failure(output) == :youtube_bot_challenge
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
