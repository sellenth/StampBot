defmodule DragNStamp.Timestamps.CaptionFallback do
  @moduledoc """
  Generates timestamps by summarising YouTube captions when the video+VLM flow
  cannot be used.
  """

  alias DragNStamp.SEO.VideoMetadata
  alias DragNStamp.Timestamps.{GeminiClient, Parser}
  alias DragNStamp.YouTube.Captions

  @caption_merge_window_ms 15_000
  @caption_char_limit 60_000

  @type attempt_meta :: map()

  @spec process(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary(), attempt_meta}
          | {:error, atom(), String.t(), attempt_meta}
  def process(channel_name, url, api_key, opts \\ []) do
    trigger = Keyword.get(opts, :trigger)

    case VideoMetadata.extract_video_id(url) do
      {:ok, video_id} ->
        maybe_process_with_video_id(video_id, channel_name, url, api_key, trigger)

      {:error, reason} ->
        attempt =
          build_caption_attempt_meta(nil, "failure", %{
            "reason" => inspect(reason),
            "failure_reason" => "video_id_not_found",
            "video_url" => url,
            "trigger" => trigger
          })

        {:error, :video_id_not_found, failure_message(:video_id_not_found), attempt}
    end
  end

  defp maybe_process_with_video_id(_video_id, _channel_name, url, api_key, trigger)
       when api_key in [nil, ""] do
    attempt =
      build_caption_attempt_meta(nil, "failure", %{
        "reason" => "missing_gemini_api_key",
        "failure_reason" => "missing_api_key",
        "video_url" => url,
        "trigger" => trigger
      })

    {:error, :missing_api_key, failure_message(:missing_api_key), attempt}
  end

  defp maybe_process_with_video_id(video_id, channel_name, url, api_key, trigger) do
    case Captions.fetch_transcript(video_id) do
      {:ok, %{segments: segments, context: caption_context}} ->
        case build_transcript_payload(segments) do
          {:ok, transcript_text, stats} ->
            case summarize_captions(channel_name, transcript_text, api_key) do
              {:ok, cleaned} ->
                attempt =
                  build_caption_attempt_meta(video_id, "success", %{
                    "caption_context" => caption_context,
                    "transcript_stats" => stats,
                    "prompt_character_count" => String.length(transcript_text),
                    "model" => "gemini-2.5-flash",
                    "video_url" => url,
                    "trigger" => trigger
                  })

                {:ok, cleaned, attempt}

              {:error, reason_atom, info} ->
                attempt =
                  build_failure_attempt(
                    video_id,
                    caption_context,
                    url,
                    trigger,
                    reason_atom,
                    stats,
                    info
                  )

                {:error, reason_atom, failure_message(reason_atom), attempt}
            end

          {:error, reason_atom, stats} ->
            attempt =
              build_failure_attempt(
                video_id,
                caption_context,
                url,
                trigger,
                reason_atom,
                stats,
                nil
              )

            {:error, reason_atom, failure_message(reason_atom), attempt}
        end

      {:error, reason, context} ->
        failure_reason = caption_fetch_failure_reason(reason)

        attempt =
          build_caption_attempt_meta(video_id, "failure", %{
            "caption_context" => context,
            "reason" => inspect(reason),
            "failure_reason" => Atom.to_string(failure_reason),
            "video_url" => url,
            "trigger" => trigger
          })

        {:error, failure_reason, failure_message(failure_reason), attempt}
    end
  end

  defp build_failure_attempt(video_id, caption_context, url, trigger, reason_atom, stats, info) do
    extra =
      %{
        "caption_context" => caption_context,
        "failure_reason" => Atom.to_string(reason_atom),
        "video_url" => url,
        "trigger" => trigger
      }
      |> maybe_put_transcript_stats(stats)
      |> maybe_put_detail(info)

    build_caption_attempt_meta(video_id, "failure", extra)
  end

  defp summarize_captions(channel_name, transcript_text, api_key) do
    prompt = build_caption_prompt(channel_name, transcript_text)

    case GeminiClient.text_only(prompt, api_key) do
      {:ok, response} when is_binary(response) ->
        case Parser.extract_timestamps_only(response) do
          cleaned when is_binary(cleaned) ->
            cleaned_trimmed = String.trim(cleaned)

            if cleaned_trimmed != "" do
              {:ok, cleaned_trimmed}
            else
              {:error, :no_timestamps, response}
            end

          other ->
            {:error, :timestamp_extraction_failed, other}
        end

      {:ok, _response} ->
        {:error, :gemini_error, :non_binary_response}

      {:error, reason} ->
        {:error, :gemini_error, reason}
    end
  end

  defp build_caption_prompt(channel_name, transcript_text) do
    trimmed =
      channel_name
      |> case do
        nil -> "anonymous"
        other -> String.trim(other)
      end

    channel_line =
      if trimmed == "" or String.downcase(trimmed) == "anonymous" do
        "The channel name was not supplied. Do not reference a channel name."
      else
        "Channel name is #{trimmed}."
      end

    """
    Generate 10-14 engaging YouTube timestamps based solely on the transcript below.
    #{channel_line}
    Use 8-12 words per timestamp. Progress the timeline in order and highlight the most significant beats.
    Format as YouTube description lines like `0:00 A short teaser of the moment`.
    One timestamp per line. No bullet points, no extra commentary or closing remarks.
    Avoid punctuation that would turn timestamps into clickable URLs in YouTube comments (prefer spaces or dashes).
    Be accurate to the transcript and keep any humor subtle.
    <transcript>
    #{transcript_text}
    </transcript>
    """
  end

  defp build_transcript_payload(segments) when is_list(segments) do
    lines =
      segments
      |> collapse_segments(@caption_merge_window_ms)
      |> Enum.reject(&(String.trim(&1) == ""))

    original_line_count = length(lines)
    {trimmed_lines, truncated?} = trim_lines_to_char_limit(lines, @caption_char_limit)
    transcript_text = trimmed_lines |> Enum.join("\n") |> String.trim()

    stats = %{
      line_count: original_line_count,
      used_line_count: length(trimmed_lines),
      truncated: truncated?,
      char_count: String.length(transcript_text)
    }

    if transcript_text == "" do
      {:error, :transcript_empty, stats}
    else
      {:ok, transcript_text, stats}
    end
  end

  defp collapse_segments(segments, window_ms) do
    {reversed, current} =
      Enum.reduce(segments, {[], nil}, fn
        %{text: text}, acc when text in [nil, ""] ->
          acc

        %{start_ms: start_ms, end_ms: end_ms, text: text}, {chunks, nil} ->
          {chunks, %{start_ms: start_ms, last_ms: end_ms, texts: [text]}}

        %{start_ms: start_ms, end_ms: end_ms, text: text}, {chunks, current_chunk} ->
          if start_ms - current_chunk.last_ms <= window_ms do
            updated =
              current_chunk
              |> Map.update!(:texts, fn texts -> [text | texts] end)
              |> Map.put(:last_ms, max(end_ms, current_chunk.last_ms))

            {chunks, updated}
          else
            finalized = finalize_chunk(current_chunk)
            {[finalized | chunks], %{start_ms: start_ms, last_ms: end_ms, texts: [text]}}
          end
      end)

    chunks =
      case current do
        nil -> reversed
        chunk -> [finalize_chunk(chunk) | reversed]
      end

    chunks
    |> Enum.reverse()
    |> Enum.map(fn %{start_ms: start_ms, text: text} ->
      "#{format_caption_time(start_ms)} #{text}"
    end)
  end

  defp finalize_chunk(%{start_ms: start_ms, last_ms: last_ms, texts: texts}) do
    text =
      texts
      |> Enum.reverse()
      |> Enum.join(" ")
      |> normalize_whitespace()

    %{start_ms: start_ms, last_ms: last_ms, text: text}
  end

  defp normalize_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp trim_lines_to_char_limit(lines, limit) when is_list(lines) do
    {acc, _total, truncated?} =
      Enum.reduce(lines, {[], 0, false}, fn line, {acc, total, truncated?} ->
        cond do
          truncated? ->
            {acc, total, truncated?}

          true ->
            separator = if acc == [], do: 0, else: 1
            potential_total = total + String.length(line) + separator

            cond do
              potential_total <= limit ->
                {[line | acc], potential_total, truncated?}

              acc == [] ->
                trimmed = String.slice(line, 0, limit)
                {[trimmed | acc], limit, true}

              true ->
                {acc, total, true}
            end
        end
      end)

    {Enum.reverse(acc), truncated?}
  end

  defp format_caption_time(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      "#{hours}:#{pad_two_digits(minutes)}:#{pad_two_digits(seconds)}"
    else
      "#{minutes}:#{pad_two_digits(seconds)}"
    end
  end

  defp pad_two_digits(value) when value < 10, do: "0#{value}"
  defp pad_two_digits(value), do: Integer.to_string(value)

  defp caption_fetch_failure_reason(reason) do
    case reason do
      :no_tracks -> :captions_unavailable
      :no_tracks_available -> :captions_unavailable
      :no_subtitles -> :captions_unavailable
      :no_cues -> :captions_unavailable
      :subtitle_file_missing -> :captions_unavailable
      :empty_segments -> :captions_empty
      :no_segments -> :captions_empty
      {:invalid_caption_payload, _} -> :captions_fetch_failed
      {:http_error, _} -> :captions_fetch_failed
      {:request_failed, _} -> :captions_fetch_failed
      {:yt_dlp_failed, _} -> :captions_fetch_failed
      {:subtitle_directory_error, _} -> :captions_fetch_failed
      :invalid_cue -> :captions_fetch_failed
      {:invalid_timecode, _} -> :captions_fetch_failed
      {:invalid_time_parts, _} -> :captions_fetch_failed
      {:invalid_float, _} -> :captions_fetch_failed
      {:invalid_integer, _} -> :captions_fetch_failed
      _ -> :captions_fetch_failed
    end
  end

  def failure_message(:missing_api_key),
    do:
      "We couldn't access our caption summarizer right now. Please try again later—this video is saved for future analysis."

  def failure_message(:video_id_not_found),
    do:
      "We couldn't read this YouTube link, so caption summarization is paused. We've saved it for follow-up."

  def failure_message(:captions_unavailable),
    do:
      "Auto timestamps need captions, and we couldn't find any for this longer video. It's saved so we can re-check later."

  def failure_message(:captions_empty),
    do:
      "The available captions were empty or unusable, so timestamps aren't ready yet. We've stored this video for review."

  def failure_message(:captions_fetch_failed),
    do: "We hit an issue fetching captions from YouTube. It's logged for future analysis."

  def failure_message(:transcript_empty),
    do:
      "Captions didn't contain enough usable speech to build timestamps. We'll keep this video on file to retry."

  def failure_message(:gemini_error),
    do:
      "Gemini had trouble summarizing the captions. We've saved the attempt and will keep an eye on it."

  def failure_message(:timestamp_extraction_failed),
    do: "Gemini responded without clear timestamps. We've saved the output for debugging."

  def failure_message(:no_timestamps),
    do: "Gemini didn't produce usable timestamps from the captions. We'll review this later."

  def failure_message(_other),
    do:
      "We couldn't create timestamps from captions yet, but the video is stored so we can revisit it."

  defp build_caption_attempt_meta(video_id, result, extra) when is_map(extra) do
    base = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "result" => result
    }

    base =
      if video_id do
        Map.put(base, "video_id", video_id)
      else
        base
      end

    base
    |> Map.merge(stringify_keys(extra))
  end

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner_value} ->
      string_key =
        case key do
          k when is_binary(k) -> k
          k when is_atom(k) -> Atom.to_string(k)
          other -> inspect(other)
        end

      {string_key, stringify_keys(inner_value)}
    end)
    |> Enum.into(%{})
  end

  defp stringify_keys(value) when is_list(value) do
    Enum.map(value, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value

  defp maybe_put_transcript_stats(map, nil), do: map
  defp maybe_put_transcript_stats(map, stats) when stats == %{}, do: map
  defp maybe_put_transcript_stats(map, stats), do: Map.put(map, "transcript_stats", stats)

  defp maybe_put_detail(map, nil), do: map

  defp maybe_put_detail(map, value) when is_binary(value) and value != "",
    do: Map.put(map, "detail", String.slice(value, 0, 500))

  defp maybe_put_detail(map, value) when is_binary(value), do: map

  defp maybe_put_detail(map, value) when is_map(value) or is_list(value),
    do: Map.put(map, "detail", value |> inspect() |> String.slice(0, 500))

  defp maybe_put_detail(map, value),
    do: Map.put(map, "detail", inspect(value) |> String.slice(0, 500))
end
