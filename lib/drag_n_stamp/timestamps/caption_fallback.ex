defmodule DragNStamp.Timestamps.CaptionFallback do
  @moduledoc """
  Generates timestamps by summarising YouTube captions when the video+VLM flow
  cannot be used.
  """

  alias DragNStamp.SEO.VideoMetadata
  alias DragNStamp.{ProcessingAttempts, WorkBudget}

  alias DragNStamp.Timestamps.{
    CaptionCheckpoint,
    CostEstimator,
    GeminiClient,
    Prompts,
    TimestampSet
  }

  alias DragNStamp.YouTube.Captions

  @caption_merge_window_ms 15_000
  @caption_char_limit 60_000
  @caption_chunk_window_ms 15 * 60_000

  @type attempt_meta :: map()

  @doc """
  Summarizes every caption excerpt, retaining timecodes from the original video.

  `:max_seconds` supplies a known video duration. When it is unavailable, the last
  caption end provides a conservative output bound, recorded separately from the
  video's duration. The `:fetch_transcript_fun` and `:generate_fun` options allow
  callers to replace acquisition and model IO without replacing preprocessing.
  """
  @spec process(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary(), attempt_meta}
          | {:error, atom(), String.t(), attempt_meta}
  def process(channel_name, url, api_key, opts \\ []) do
    trigger = Keyword.get(opts, :trigger)

    case VideoMetadata.extract_video_id(url) do
      {:ok, video_id} ->
        maybe_process_with_video_id(video_id, channel_name, url, api_key, opts)

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

  defp maybe_process_with_video_id(_video_id, _channel_name, url, api_key, opts)
       when api_key in [nil, ""] do
    attempt =
      build_caption_attempt_meta(nil, "failure", %{
        "reason" => "missing_gemini_api_key",
        "failure_reason" => "missing_api_key",
        "video_url" => url,
        "trigger" => Keyword.get(opts, :trigger)
      })

    {:error, :missing_api_key, failure_message(:missing_api_key), attempt}
  end

  defp maybe_process_with_video_id(video_id, channel_name, url, api_key, opts) do
    trigger = Keyword.get(opts, :trigger)
    fetch_transcript = Keyword.get(opts, :fetch_transcript_fun, &Captions.fetch_transcript/1)

    fetched =
      ProcessingAttempts.around(
        %{
          kind: :stage,
          stage: "caption_acquisition",
          provider: "youtube"
        },
        fn -> fetch_transcript.(video_id) end
      )

    case fetched do
      {:ok, %{segments: segments, context: caption_context}} ->
        case build_transcript_payload(segments, opts) do
          {:ok, chunks, stats} ->
            case summarize_captions(
                   channel_name,
                   chunks,
                   api_key,
                   stats.output_bound_seconds,
                   opts
                 ) do
              {:ok, cleaned, model, estimated_cost_usd, reused_chunks} ->
                attempt =
                  build_caption_attempt_meta(video_id, "success", %{
                    "caption_context" => caption_context,
                    "transcript_stats" =>
                      Map.merge(stats, %{
                        completed_chunk_count: length(chunks),
                        reused_chunk_count: reused_chunks
                      }),
                    "prompt_character_count" => stats.char_count,
                    "model" => model,
                    "estimated_cost_usd" => CostEstimator.serialize(estimated_cost_usd),
                    "video_url" => url,
                    "trigger" => trigger
                  })
                  |> put_duration_metadata(stats)

                {:ok, cleaned, attempt}

              {:error, reason_atom, info, estimated_cost_usd, completed_chunk_count,
               reused_chunks} ->
                attempt =
                  build_failure_attempt(
                    video_id,
                    caption_context,
                    url,
                    trigger,
                    reason_atom,
                    Map.merge(stats, %{
                      completed_chunk_count: completed_chunk_count,
                      reused_chunk_count: reused_chunks
                    }),
                    info
                  )
                  |> put_duration_metadata(stats)
                  |> Map.put("estimated_cost_usd", CostEstimator.serialize(estimated_cost_usd))

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
            "retryable" => retryable_acquisition_failure?(failure_reason),
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
        "retryable" => retryable_generation_failure?(info),
        "video_url" => url,
        "trigger" => trigger
      }
      |> maybe_put_transcript_stats(stats)
      |> maybe_put_detail(info)

    build_caption_attempt_meta(video_id, "failure", extra)
  end

  defp summarize_captions(channel_name, chunks, api_key, max_seconds, opts) do
    generate = Keyword.get(opts, :generate_fun, &GeminiClient.text_only_detailed/3)

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], nil, nil, 0}, fn {chunk, index},
                                                    {:ok, candidates, _model, cost, reused} ->
      bounds = [
        min_seconds: div(chunk.start_ms, 1_000),
        max_seconds: min(ceil_seconds(chunk.end_ms), max_seconds)
      ]

      prompt =
        Prompts.captions(channel_name, chunk.text,
          start_seconds: div(chunk.start_ms, 1_000),
          end_seconds: ceil_seconds(chunk.end_ms),
          max_seconds: max_seconds
        )

      hash = CaptionCheckpoint.key(prompt, bounds)

      generated =
        ProcessingAttempts.around(
          %{
            kind: :chunk,
            stage: "caption_chunk",
            provider: "gemini",
            operation: :text,
            chunk_index: index,
            start_seconds: div(chunk.start_ms, 1_000),
            end_seconds: ceil_seconds(chunk.end_ms),
            input_bytes: byte_size(chunk.text),
            prompt_version: "captions-2026-09-10-v3"
          },
          fn ->
            response =
              case CaptionCheckpoint.fetch(index, hash, bounds) do
                {:ok, result} -> {:ok, result}
                :miss -> generate.(prompt, api_key, bounds)
              end

            case response do
              {:ok, %GeminiClient.Result{} = result} ->
                case validate_chunk_timestamps(result.timestamps, chunk, max_seconds) do
                  :ok ->
                    unless result.cache_hit, do: CaptionCheckpoint.put(index, hash, result)
                    {:ok, result}

                  {:error, reason} ->
                    {:error,
                     %{
                       kind: :timestamp_outside_excerpt,
                       reason: reason,
                       request_cost_usd:
                         result |> CostEstimator.estimate_usd() |> CostEstimator.serialize()
                     }}
                end

              {:error, reason} ->
                {:error, reason}

              _ ->
                {:error, %{kind: :invalid_model_output}}
            end
          end
        )

      case generated do
        {:ok, result} ->
          {:cont,
           {:ok, [result.timestamps | candidates], result.model_version || result.model,
            CostEstimator.add(cost, CostEstimator.estimate_usd(result)),
            reused + if(result.cache_hit, do: 1, else: 0)}}

        {:error, reason} ->
          failure =
            case reason do
              %{kind: kind}
              when kind in [
                     :timestamp_outside_excerpt,
                     :input_limit_exceeded,
                     :work_budget_exceeded,
                     :total_budget_exceeded
                   ] ->
                kind

              %{kind: :invalid_model_output, reason: {kind, _, _, _}}
              when kind == :timestamp_outside_excerpt ->
                :timestamp_outside_excerpt

              %{kind: :invalid_model_output, reason: {:timestamp_out_of_bounds, _, _}} ->
                :timestamp_outside_excerpt

              %{kind: :invalid_model_output} ->
                :timestamp_extraction_failed

              _ ->
                :gemini_error
            end

          extra_cost = if is_map(reason), do: CostEstimator.parse(reason[:request_cost_usd])

          {:halt,
           {:error, failure, %{chunk_number: index, reason: reason},
            CostEstimator.add(cost, extra_cost), index - 1, reused}}
      end
    end)
    |> case do
      {:ok, candidates, model, cost, reused} ->
        content =
          candidates
          |> Enum.reverse()
          |> List.flatten()
          |> Enum.sort_by(& &1.seconds)
          |> Enum.uniq_by(& &1.seconds)
          |> TimestampSet.render()

        {:ok, content, model, cost, reused}

      error ->
        error
    end
  end

  defp validate_chunk_timestamps(timestamps, chunk, max_seconds) when is_list(timestamps) do
    first_seconds = div(chunk.start_ms, 1_000)
    last_seconds = min(ceil_seconds(chunk.end_ms), max_seconds)

    cond do
      timestamps == [] ->
        {:error, :no_timestamps}

      true ->
        case Enum.find(timestamps, &(&1.seconds < first_seconds or &1.seconds > last_seconds)) do
          nil ->
            :ok

          timestamp ->
            {:error, {:timestamp_outside_excerpt, timestamp.seconds, first_seconds, last_seconds}}
        end
    end
  end

  defp validate_chunk_timestamps(_timestamps, _chunk, _max_seconds),
    do: {:error, :no_timestamps}

  defp build_transcript_payload(segments, opts) when is_list(segments) do
    case WorkBudget.check_transcript(ProcessingAttempts.context(), segments) do
      :ok -> build_transcript_chunks(segments, opts)
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  defp build_transcript_chunks(segments, opts) do
    lines =
      segments
      |> Enum.filter(&valid_segment?/1)
      |> Enum.sort_by(& &1.start_ms)
      |> collapse_segments(@caption_merge_window_ms)
      |> Enum.flat_map(&split_long_line(&1, @caption_char_limit))

    chunks = chunk_lines(lines, @caption_char_limit, @caption_chunk_window_ms)

    stats = %{
      line_count: length(lines),
      used_line_count: length(lines),
      truncated: false,
      char_count: Enum.reduce(chunks, 0, &(&1.char_count + &2)),
      chunk_count: length(chunks)
    }

    if chunks == [] do
      {:error, :transcript_empty, stats}
    else
      transcript_end_seconds = chunks |> Enum.map(& &1.end_ms) |> Enum.max() |> ceil_seconds()
      known_seconds = Keyword.get(opts, :max_seconds)
      known_duration? = is_integer(known_seconds) and known_seconds > 0

      stats =
        Map.merge(stats, %{
          coverage_end_seconds: transcript_end_seconds,
          output_bound_seconds:
            if(known_duration?, do: known_seconds, else: transcript_end_seconds),
          duration_source: if(known_duration?, do: "video_metadata", else: "transcript_end")
        })

      with :ok <- WorkBudget.check_chunks(ProcessingAttempts.context(), length(chunks)),
           :ok <-
             WorkBudget.check_duration(ProcessingAttempts.context(), stats.output_bound_seconds) do
        {:ok, chunks, stats}
      else
        {:error, reason} -> {:error, reason, stats}
      end
    end
  end

  defp valid_segment?(%{start_ms: start_ms, end_ms: end_ms, text: text})
       when is_integer(start_ms) and start_ms >= 0 and is_integer(end_ms) and end_ms > start_ms and
              is_binary(text),
       do: String.trim(text) != ""

  defp valid_segment?(_segment), do: false

  defp collapse_segments(segments, window_ms) do
    {reversed, current} =
      Enum.reduce(segments, {[], nil}, fn
        %{text: text}, acc when text in [nil, ""] ->
          acc

        %{start_ms: start_ms, end_ms: end_ms, text: text}, {chunks, nil} ->
          {chunks, %{start_ms: start_ms, last_ms: end_ms, texts: [text]}}

        %{start_ms: start_ms, end_ms: end_ms, text: text}, {chunks, current_chunk} ->
          if max(end_ms, current_chunk.last_ms) - current_chunk.start_ms <= window_ms do
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

    Enum.reverse(chunks)
  end

  defp finalize_chunk(%{start_ms: start_ms, last_ms: last_ms, texts: texts}) do
    text =
      texts
      |> Enum.reverse()
      |> Enum.join(" ")
      |> normalize_whitespace()

    %{start_ms: start_ms, end_ms: last_ms, text: text}
  end

  defp normalize_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp split_long_line(line, limit) do
    prefix = "#{format_caption_time(line.start_ms)} "

    line.text
    |> split_text(limit - String.length(prefix))
    |> Enum.map(&%{line | text: prefix <> &1})
  end

  defp split_text(text, limit) do
    if String.length(text) <= limit do
      [text]
    else
      {first, rest} = String.split_at(text, limit)
      [first | split_text(rest, limit)]
    end
  end

  defp chunk_lines(lines, char_limit, window_ms) do
    {chunks, current} =
      Enum.reduce(lines, {[], nil}, fn line, {chunks, current} ->
        line_length = String.length(line.text)

        cond do
          is_nil(current) ->
            {chunks, new_transcript_chunk(line, line_length)}

          current.char_count + line_length + 1 <= char_limit and
              max(current.end_ms, line.end_ms) - current.start_ms <= window_ms ->
            updated = %{
              current
              | end_ms: max(current.end_ms, line.end_ms),
                lines: [line.text | current.lines],
                char_count: current.char_count + line_length + 1
            }

            {chunks, updated}

          true ->
            {[finalize_transcript_chunk(current) | chunks],
             new_transcript_chunk(line, line_length)}
        end
      end)

    case current do
      nil -> []
      current -> Enum.reverse([finalize_transcript_chunk(current) | chunks])
    end
  end

  defp new_transcript_chunk(line, line_length) do
    %{
      start_ms: line.start_ms,
      end_ms: line.end_ms,
      lines: [line.text],
      char_count: line_length
    }
  end

  defp finalize_transcript_chunk(chunk) do
    chunk
    |> Map.put(:text, chunk.lines |> Enum.reverse() |> Enum.join("\n"))
    |> Map.delete(:lines)
  end

  defp put_duration_metadata(attempt, stats) do
    attempt =
      attempt
      |> Map.put("output_bound_seconds", stats.output_bound_seconds)
      |> Map.put("duration_source", stats.duration_source)

    if stats.duration_source == "video_metadata" do
      Map.put(attempt, "video_seconds", stats.output_bound_seconds)
    else
      attempt
    end
  end

  defp ceil_seconds(ms), do: div(ms + 999, 1_000)

  defp retryable_acquisition_failure?(reason),
    do: reason in [:youtube_network_error, :youtube_rate_limited]

  defp retryable_generation_failure?(%{reason: %{kind: :transport}}), do: true

  defp retryable_generation_failure?(%{reason: %{kind: :http, status: status}})
       when is_integer(status),
       do: status in [408, 409, 425, 429] or status in 500..599

  defp retryable_generation_failure?(_info), do: false

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

  @doc false
  def caption_fetch_failure_reason(reason) do
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
      {:yt_dlp_failed, :unsupported_option, _} -> :caption_downloader_outdated
      {:yt_dlp_failed, :unsupported_runtime, _} -> :caption_runtime_outdated
      {:yt_dlp_failed, :binary_unavailable, _} -> :caption_downloader_unavailable
      {:yt_dlp_failed, :cookies_invalid, _} -> :youtube_auth_failed
      {:yt_dlp_failed, :youtube_bot_challenge, _} -> :youtube_bot_challenge
      {:yt_dlp_failed, :youtube_auth_required, _} -> :youtube_auth_failed
      {:yt_dlp_failed, :rate_limited, _} -> :youtube_rate_limited
      {:yt_dlp_failed, :network_error, _} -> :youtube_network_error
      {:yt_dlp_failed, :video_unavailable, _} -> :video_unavailable
      {:yt_dlp_failed, :no_subtitles, _} -> :captions_unavailable
      {:yt_dlp_failed, _category, _} -> :captions_fetch_failed
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

  def failure_message(reason)
      when reason in [:input_limit_exceeded, :work_budget_exceeded, :total_budget_exceeded],
      do: WorkBudget.message(reason)

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

  def failure_message(:caption_downloader_outdated),
    do:
      "Our YouTube caption downloader is out of date and needs a service update. This video has been saved for a retry."

  def failure_message(:caption_downloader_unavailable),
    do:
      "Our YouTube caption downloader isn't available on the server right now. This video has been saved for a retry."

  def failure_message(:caption_runtime_outdated),
    do:
      "The server's YouTube caption runtime is out of date and needs a service update. This video has been saved for a retry."

  def failure_message(:youtube_auth_failed),
    do:
      "YouTube rejected StampBot's caption access credentials. This is a server-side access issue, not necessarily a problem with the submitted video."

  def failure_message(:youtube_bot_challenge),
    do:
      "YouTube blocked StampBot's caption request with a bot-verification challenge. We could not retrieve captions from the server."

  def failure_message(:youtube_rate_limited),
    do:
      "YouTube temporarily rate-limited caption requests. This video has been saved so it can be retried later."

  def failure_message(:youtube_network_error),
    do:
      "The server couldn't reach YouTube's caption service. This video has been saved for a retry."

  def failure_message(:video_unavailable),
    do:
      "YouTube reports that this video is private, removed, or otherwise unavailable to the server."

  def failure_message(:transcript_empty),
    do:
      "Captions didn't contain enough usable speech to build timestamps. We'll keep this video on file to retry."

  def failure_message(:gemini_error),
    do:
      "The caption summarizer could not complete this attempt. Successful excerpts are saved for a retry."

  def failure_message(:timestamp_outside_excerpt),
    do:
      "The caption summarizer returned chapters outside the excerpt's time range. This attempt stopped; successful excerpts are saved for a retry."

  def failure_message(:timestamp_extraction_failed),
    do:
      "The caption summarizer returned invalid chapter data. This attempt stopped; successful excerpts are saved for a retry."

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

    base = if result == "failure", do: Map.put(base, "retryable", false), else: base

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
