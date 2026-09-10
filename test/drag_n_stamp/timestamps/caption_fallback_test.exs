defmodule DragNStamp.Timestamps.CaptionFallbackTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.{CaptionFallback, GeminiClient, TimestampSet}

  describe "process/4 transcript coverage" do
    test "continuous narration retains timecodes and every cue across bounded excerpts" do
      parent = self()
      segments = continuous_segments(1_800)

      generate = fn prompt, _api_key, opts ->
        transcript = transcript_from_prompt(prompt)
        send(parent, {:excerpt, transcript, opts})
        {:ok, model_result(excerpt_timestamps(transcript))}
      end

      assert {:ok, content, attempt} =
               CaptionFallback.process("Example", video_url(), "test-key",
                 max_seconds: 3_600,
                 fetch_transcript_fun: transcript_fetcher(Enum.reverse(segments)),
                 generate_fun: generate
               )

      stats = attempt["transcript_stats"]
      assert stats["chunk_count"] >= 4
      assert stats["completed_chunk_count"] == stats["chunk_count"]
      assert stats["line_count"] > 200
      assert stats["used_line_count"] == stats["line_count"]
      assert stats["char_count"] > 60_000
      refute stats["truncated"]
      assert attempt["video_seconds"] == 3_600
      assert attempt["output_bound_seconds"] == 3_600
      assert attempt["duration_source"] == "video_metadata"

      transcripts =
        for _ <- 1..stats["chunk_count"] do
          assert_receive {:excerpt, transcript, opts}
          assert opts[:min_seconds] == hd(timecodes(transcript))
          assert opts[:max_seconds] <= 3_600
          assert opts[:max_seconds] - opts[:min_seconds] <= 900
          assert String.length(transcript) <= 60_000
          transcript
        end

      cue_ids =
        transcripts
        |> Enum.flat_map(&Regex.scan(~r/CUE_(\d+)\b/, &1, capture: :all_but_first))
        |> List.flatten()
        |> Enum.map(&String.to_integer/1)

      assert cue_ids == Enum.to_list(0..1_799)

      line_seconds = transcripts |> Enum.flat_map(&timecodes/1)
      assert line_seconds == Enum.sort(line_seconds)
      assert Enum.at(line_seconds, 1) in 1..15
      assert List.last(timecodes(content)) > 3_500
    end

    test "a cue larger than the character budget is split without dropping its text" do
      parent = self()
      source_text = String.duplicate("多言語の説明とevidence", 6_000)
      segment = %{start_ms: 20_000, end_ms: 27_501, text: source_text}

      generate = fn prompt, _api_key, opts ->
        transcript = transcript_from_prompt(prompt)
        send(parent, {:excerpt, transcript, opts})
        {:ok, model_result(excerpt_timestamps(transcript))}
      end

      assert {:ok, content, attempt} =
               CaptionFallback.process(nil, video_url(), "test-key",
                 fetch_transcript_fun: transcript_fetcher([segment]),
                 generate_fun: generate
               )

      assert attempt["transcript_stats"]["chunk_count"] == 2
      assert attempt["output_bound_seconds"] == 28
      assert attempt["duration_source"] == "transcript_end"
      refute Map.has_key?(attempt, "video_seconds")

      supplied_text =
        for _ <- 1..2 do
          assert_receive {:excerpt, transcript, opts}
          assert opts[:max_seconds] == 28
          assert String.length(transcript) <= 60_000
          String.replace_prefix(transcript, "0:20 ", "")
        end

      assert Enum.join(supplied_text) == source_text
      assert timecodes(content) == [20]
    end

    test "a later excerpt failure fails the whole result and records completed work" do
      parent = self()
      counter = :counters.new(1, [])

      generate = fn prompt, _api_key, _opts ->
        :counters.add(counter, 1, 1)
        send(parent, :generated)

        if :counters.get(counter, 1) == 1 do
          {:ok, model_result(prompt |> transcript_from_prompt() |> excerpt_timestamps())}
        else
          {:error, %{kind: :http, status: 429}}
        end
      end

      assert {:error, :gemini_error, _message, attempt} =
               CaptionFallback.process(nil, video_url(), "test-key",
                 max_seconds: 3_600,
                 fetch_transcript_fun: transcript_fetcher(continuous_segments(1_800)),
                 generate_fun: generate
               )

      assert :counters.get(counter, 1) == 2
      assert attempt["transcript_stats"]["completed_chunk_count"] == 1
      assert attempt["transcript_stats"]["chunk_count"] >= 4
      assert attempt["detail"] =~ "chunk_number: 2"
      assert attempt["detail"] =~ "429"
      assert attempt["retryable"]
      assert Decimal.gt?(Decimal.new(attempt["estimated_cost_usd"]), Decimal.new(0))
    end

    test "timestamps restarted at zero in a later excerpt cannot become a successful result" do
      counter = :counters.new(1, [])

      generate = fn prompt, _api_key, _opts ->
        :counters.add(counter, 1, 1)

        timestamps =
          if :counters.get(counter, 1) == 1 do
            prompt |> transcript_from_prompt() |> excerpt_timestamps()
          else
            [%{seconds: 0, title: "An incorrect timestamp restarts the clock at zero"}]
          end

        {:ok, model_result(timestamps)}
      end

      assert {:error, :timestamp_outside_excerpt, _message, attempt} =
               CaptionFallback.process(nil, video_url(), "test-key",
                 max_seconds: 3_600,
                 fetch_transcript_fun: transcript_fetcher(continuous_segments(1_800)),
                 generate_fun: generate
               )

      assert attempt["transcript_stats"]["completed_chunk_count"] == 1
      assert attempt["detail"] =~ "timestamp_outside_excerpt"
      assert attempt["detail"] =~ "chunk_number: 2"
      refute attempt["retryable"]
    end

    test "empty or unusable cues fail before any model call" do
      assert {:error, :transcript_empty, _message, attempt} =
               CaptionFallback.process(nil, video_url(), "test-key",
                 fetch_transcript_fun:
                   transcript_fetcher([
                     %{start_ms: 0, end_ms: 1_000, text: "  "},
                     %{start_ms: -1, end_ms: 1_000, text: "Invalid timing"}
                   ]),
                 generate_fun: fn _, _, _ ->
                   flunk("Empty transcripts must not invoke a model")
                 end
               )

      assert attempt["transcript_stats"]["chunk_count"] == 0
      refute attempt["retryable"]
    end

    test "only transient model failures request a job retry" do
      cases = [
        {%{kind: :transport, reason: :timeout}, true},
        {%{kind: :http, status: 408}, true},
        {%{kind: :http, status: 409}, true},
        {%{kind: :http, status: 425}, true},
        {%{kind: :http, status: 429}, true},
        {%{kind: :http, status: 503}, true},
        {%{kind: :http, status: 400}, false},
        {%{kind: :http, status: 401}, false},
        {%{kind: :invalid_model_output, reason: :no_timestamps}, false}
      ]

      for {reason, retryable?} <- cases do
        assert {:error, category, _message, attempt} =
                 CaptionFallback.process(nil, video_url(), "test-key",
                   fetch_transcript_fun: transcript_fetcher(continuous_segments(2)),
                   generate_fun: fn _, _, _ -> {:error, reason} end
                 )

        assert category ==
                 if(reason[:kind] == :invalid_model_output,
                   do: :timestamp_extraction_failed,
                   else: :gemini_error
                 )

        assert attempt["retryable"] == retryable?, inspect(reason)
      end
    end

    test "acquisition errors retain their transient or terminal classification" do
      cases = [
        network_error: true,
        rate_limited: true,
        cookies_invalid: false,
        video_unavailable: false,
        no_subtitles: false
      ]

      for {reason, retryable?} <- cases do
        assert {:error, _category, _message, attempt} =
                 CaptionFallback.process(nil, video_url(), "test-key",
                   fetch_transcript_fun: fn _ ->
                     {:error, {:yt_dlp_failed, reason, %{}}, %{source: :fixture}}
                   end,
                   generate_fun: fn _, _, _ -> flunk("Acquisition failed before generation") end
                 )

        assert attempt["retryable"] == retryable?, inspect(reason)
      end
    end
  end

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

  defp continuous_segments(count) do
    for index <- 0..(count - 1) do
      %{
        start_ms: index * 2_000,
        end_ms: index * 2_000 + 1_900,
        text: "CUE_#{index} contains useful evidence from this part of the recording."
      }
    end
  end

  defp transcript_fetcher(segments) do
    fn _video_id -> {:ok, %{segments: segments, context: %{source: :fixture}}} end
  end

  defp video_url, do: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

  defp transcript_from_prompt(prompt) do
    [_, transcript] = String.split(prompt, "BEGIN UNTRUSTED TRANSCRIPT\n", parts: 2)
    [transcript, _] = String.split(transcript, "\nEND UNTRUSTED TRANSCRIPT", parts: 2)
    transcript
  end

  defp excerpt_timestamps(transcript) do
    seconds = timecodes(transcript)

    [List.first(seconds), List.last(seconds)]
    |> Enum.uniq()
    |> Enum.map(&%{seconds: &1, title: "Transcript evidence identifies the topic at this point"})
  end

  defp timecodes(text) do
    Regex.scan(~r/^(\d+:\d{2}(?::\d{2})?) /m, text, capture: :all_but_first)
    |> Enum.map(fn [timecode] ->
      timecode
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)
      |> Enum.reduce(0, &(&2 * 60 + &1))
    end)
  end

  defp model_result(timestamps) do
    %GeminiClient.Result{
      content: TimestampSet.render(timestamps),
      timestamps: timestamps,
      model: "gemini-3.5-flash-lite",
      duration_ms: 1,
      attempts: 1,
      usage: %{prompt_tokens: 100, output_tokens: 10, thinking_tokens: 0, cached_tokens: 0}
    }
  end
end
