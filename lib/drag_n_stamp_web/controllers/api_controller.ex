defmodule DragNStampWeb.ApiController do
  use DragNStampWeb, :controller
  require Logger
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.{PagePath, VideoMetadata}
  alias DragNStamp.YouTube.Captions

  @caption_merge_window_ms 15_000
  @caption_char_limit 60_000
  @caption_attempt_history_limit 5

  def receive_url(conn, %{"url" => url} = params) do
    username =
      case Map.get(params, "username") do
        nil ->
          "anonymous"

        "" ->
          "anonymous"

        username when is_binary(username) ->
          case String.trim(username) do
            "" -> "anonymous"
            trimmed -> trimmed
          end

        _ ->
          "anonymous"
      end

    Logger.info("Received URL: #{url}")
    Logger.info("Username: #{username}")
    Logger.info("Full params: #{inspect(params)}")

    json(conn, %{
      status: "success",
      message: "URL received",
      url: url,
      username: username,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def receive_url(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      status: "error",
      message: "URL parameter is required"
    })
  end

  defp normalize_youtube_url(url) do
    cond do
      String.contains?(url, "youtu.be/") ->
        # Extract video ID from youtu.be URL
        case Regex.run(~r/youtu\.be\/([^?&]+)/, url) do
          [_, video_id] -> "https://www.youtube.com/watch?v=#{video_id}"
          _ -> url
        end

      true ->
        url
    end
  end

  defp extract_timestamps_only(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line ->
      # Match lines that start with timestamp pattern like "0:00", "1:23", "12:34", etc.
      String.match?(line, ~r/^\s*\d+:\d+/)
    end)
    |> Enum.join("\n")
  end

  defp extract_timestamps_only(nil) do
    Logger.error("extract_timestamps_only received nil - Gemini API returned no text")
    {:error, :nil_response}
  end

  defp extract_timestamps_only(other) do
    Logger.error("extract_timestamps_only received unexpected type: #{inspect(other)}")
    {:error, :unexpected_type}
  end

  def gemini(conn, params) do
    api_key = System.get_env("GEMINI_API_KEY")
    channel_name = Map.get(params, "channel_name", "anonymous")

    submitter_username =
      case Map.get(params, "submitter_username") do
        nil ->
          "anonymous"

        "" ->
          "anonymous"

        username when is_binary(username) ->
          case String.trim(username) do
            "" -> "anonymous"
            trimmed -> trimmed
          end

        _ ->
          "anonymous"
      end

    url = Map.get(params, "url") |> normalize_youtube_url()

    Logger.info(
      "Gemini request - Channel: #{channel_name}, Submitter: #{submitter_username}, URL: #{url}"
    )

    case Repo.get_by(Timestamp, url: url) do
      %Timestamp{processing_status: :ready, distilled_content: distilled_content}
      when not is_nil(distilled_content) ->
        Logger.info("Found existing distilled timestamps for URL: #{url}")

        json(conn, %{
          status: "success",
          response: distilled_content,
          cached: true
        })

      %Timestamp{processing_status: :ready, content: content} = timestamp
      when not is_nil(content) ->
        Logger.info(
          "Found existing timestamps but no distilled version for URL: #{url}, distilling..."
        )

        distill_existing_timestamps(conn, api_key, timestamp, content, url)

      %Timestamp{processing_status: :processing} = timestamp ->
        Logger.info("Timestamp generation already in progress for URL: #{url}, returning 202")

        conn
        |> put_status(:accepted)
        |> json(%{
          status: "processing",
          message: "Timestamp generation is already in progress",
          timestamp_id: timestamp.id
        })

      %Timestamp{} = timestamp ->
        Logger.info(
          "Timestamp record present for URL: #{url} with status #{timestamp.processing_status}, attempting regeneration"
        )

        case acquire_url_lock(url) do
          :acquired ->
            try do
              generate_new_timestamps(
                conn,
                api_key,
                channel_name,
                submitter_username,
                url,
                timestamp
              )
            after
              release_url_lock(url)
            end

          :in_flight ->
            Logger.info("Duplicate request in-flight for URL: #{url}, returning 202 Accepted")

            conn
            |> put_status(:accepted)
            |> json(%{
              status: "processing",
              message: "A request for this URL is already in progress"
            })
        end

      nil ->
        Logger.info(
          "No existing timestamps found for URL: #{url}, attempting to acquire lock and call Gemini API"
        )

        case acquire_url_lock(url) do
          :acquired ->
            try do
              generate_new_timestamps(
                conn,
                api_key,
                channel_name,
                submitter_username,
                url,
                nil
              )
            after
              release_url_lock(url)
            end

          :in_flight ->
            Logger.info("Duplicate request in-flight for URL: #{url}, returning 202 Accepted")

            conn
            |> put_status(:accepted)
            |> json(%{
              status: "processing",
              message: "A request for this URL is already in progress"
            })
        end
    end
  end

  # Lightweight distributed lock to prevent concurrent processing of the same URL
  defp acquire_url_lock(url) when is_binary(url) do
    key = {:gemini_url_lock, url}

    case :global.set_lock(key, [node()], 0) do
      true -> :acquired
      false -> :in_flight
    end
  end

  defp release_url_lock(url) when is_binary(url) do
    key = {:gemini_url_lock, url}
    :global.del_lock(key)
    :ok
  end

  defp ensure_processing_timestamp(
         nil,
         channel_name,
         submitter_username,
         url
       ) do
    attrs = %{
      url: url,
      channel_name: channel_name,
      submitter_username: submitter_username,
      processing_status: :processing,
      processing_error: nil
    }

    case Repo.insert(Timestamp.changeset(%Timestamp{}, attrs)) do
      {:ok, timestamp} ->
        {:ok, timestamp, true}

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if url_conflict?(changeset) do
          case Repo.get_by(Timestamp, url: url) do
            %Timestamp{} = existing ->
              ensure_processing_timestamp(existing, channel_name, submitter_username, url)

            _ ->
              error
          end
        else
          error
        end
    end
  end

  defp ensure_processing_timestamp(
         %Timestamp{} = timestamp,
         channel_name,
         submitter_username,
         _url
       ) do
    attrs = %{
      channel_name: channel_name,
      submitter_username: submitter_username,
      processing_status: :processing,
      processing_error: nil
    }

    case Repo.update(Timestamp.changeset(timestamp, attrs)) do
      {:ok, updated} -> {:ok, updated, false}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp broadcast_timestamp_created(%Timestamp{} = timestamp) do
    Phoenix.PubSub.broadcast(
      DragNStamp.PubSub,
      "timestamps",
      {:timestamp_created, timestamp}
    )
  end

  defp broadcast_timestamp_updated(%Timestamp{} = timestamp) do
    Phoenix.PubSub.broadcast(
      DragNStamp.PubSub,
      "timestamps",
      {:timestamp_updated, timestamp}
    )
  end

  defp mark_timestamp_failed(%Timestamp{} = timestamp, reason) do
    message =
      reason
      |> error_to_string()
      |> String.slice(0, 500)

    attrs = %{
      processing_status: :failed,
      processing_error: message
    }

    result =
      case Repo.update(Timestamp.changeset(timestamp, attrs)) do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.error(
            "Failed to mark timestamp #{timestamp.id} as failed: #{inspect(changeset.errors)}"
          )

          %{timestamp | processing_status: :failed, processing_error: message}
      end

    broadcast_timestamp_updated(result)
    result
  end

  defp error_to_string(reason) when is_binary(reason), do: reason
  defp error_to_string(reason), do: inspect(reason)

  defp generate_new_timestamps(
         conn,
         api_key,
         channel_name,
         submitter_username,
         url,
         existing_timestamp
       ) do
    # Create the formatted prompt for timestamps
    formatted_prompt =
      "give me timestamps every few minutes of the important parts of this video. use 8-12 words per timestamp. structure your response as a youtube description. feel free to be slightly humorous but not cheesy. channel name is #{channel_name}. put each timestmap on its own line, no indentation, no extra lines between, NO EXTRA COMMENTARY BESIDES THE TIMESTMAPS.

      construct a timestamp in a way that doesn't create a valid link in a youtube comment.
      For example, the period is creating a link which may flag us as spam.
      <bad>
      0:00 __________ Parse.bot: ___ _____.
      </bad>
      <good>
      0:00 __________ Parse bot: ___ _____.
      </good>

      if the channel name is anonymous, that just means a name wasn't supplied, DONT REFERENCE
      ANONYMOUS.
      <bad>
      0:00 Welcome to the anonymous channel's RC helicopter extravaganza!
      </bad>
      <good>
      0:00 Welcome to the RC helicopter extravaganza!
      </good>
      "

    with {:ok, timestamp, created?} <-
           ensure_processing_timestamp(
             existing_timestamp,
             channel_name,
             submitter_username,
             url
           ) do
      if created? do
        Logger.info("Created placeholder timestamp record for URL: #{url}")
        broadcast_timestamp_created(timestamp)
      else
        broadcast_timestamp_updated(timestamp)
      end

      # Enforce a 40-minute maximum video length before analysis
      case video_too_long?(timestamp) do
        {:reject, seconds} ->
          Logger.info("Video exceeds 40-minute limit (#{seconds}s). Attempting caption-based processing.")

          case process_video_via_captions(timestamp, channel_name, url, api_key, trigger: "length_gate") do
            {:ok, cleaned, attempt_meta} ->
              attempt_meta =
                attempt_meta
                |> Map.put_new("video_seconds", seconds)

              updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

              Logger.info("Caption-based pipeline succeeded for long video #{url}")

              complete_timestamp_generation(conn, api_key, updated_timestamp, cleaned, url)

            {:error, reason_atom, friendly_message, attempt_meta} ->
              attempt_meta =
                attempt_meta
                |> Map.put_new("video_seconds", seconds)

              updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

              minutes = Integer.floor_div(seconds, 60)

              db_message =
                "[captions_fallback_failed_long_video] #{friendly_message} (length=#{minutes}m)"

              _ = mark_timestamp_failed(updated_timestamp, db_message)

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                status: "error",
                message: "#{friendly_message} This video is #{minutes} minutes long.",
                reason: Atom.to_string(reason_atom),
                max_minutes: 40,
                video_minutes: minutes,
                fallback: "captions"
              })
          end

        :ok ->
          if api_key in [nil, ""] do
            Logger.error("GEMINI_API_KEY environment variable not set")

            _ = mark_timestamp_failed(timestamp, "GEMINI_API_KEY environment variable not set")

            conn
            |> put_status(:internal_server_error)
            |> json(%{
              status: "error",
              message: "GEMINI_API_KEY environment variable not set"
            })
          else
            case call_gemini_api_with_retry(formatted_prompt, api_key, url) do
              {:ok, generated_content} ->
                complete_timestamp_generation(conn, api_key, timestamp, generated_content, url)

              {:error, reason} ->
                Logger.warning(
                  "Gemini video+ request failed with #{inspect(reason)}. Falling back to captions for #{url}"
                )

                case process_video_via_captions(
                       timestamp,
                       channel_name,
                       url,
                       api_key,
                       trigger: "vlm_failure"
                     ) do
                  {:ok, cleaned, attempt_meta} ->
                    attempt_meta =
                      attempt_meta
                      |> Map.put_new("vlm_error", inspect(reason))

                    updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

                    Logger.info("Caption-based fallback succeeded after VLM failure for #{url}")

                    complete_timestamp_generation(conn, api_key, updated_timestamp, cleaned, url)

                  {:error, fallback_reason, friendly_message, attempt_meta} ->
                    attempt_meta =
                      attempt_meta
                      |> Map.put_new("vlm_error", inspect(reason))

                    updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

                    db_message =
                      "[gemini_vlm_failed] #{inspect(reason)} | captions=#{Atom.to_string(fallback_reason)}"

                    _ = mark_timestamp_failed(updated_timestamp, db_message)

                    conn
                    |> put_status(:internal_server_error)
                    |> json(%{
                      status: "error",
                      message: friendly_message,
                      reason: Atom.to_string(fallback_reason),
                      fallback: "captions"
                    })
                end
            end
          end
      end
    else
      {:error, changeset} ->
        Logger.error("Failed to prepare timestamp record: #{inspect(changeset.errors)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          status: "error",
          message: "Failed to prepare timestamp record"
        })
    end
  end

  defp url_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:url, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  defp ensure_video_metadata(nil), do: nil

  defp ensure_video_metadata(%Timestamp{} = timestamp) do
    if metadata_ingest_enabled?() do
      case VideoMetadata.ensure_metadata(timestamp) do
        {:ok, updated} ->
          updated

        {:error, reason} ->
          Logger.debug("Metadata enrichment skipped for #{timestamp.url}: #{inspect(reason)}")
          timestamp
      end
    else
      timestamp
    end
  end

  defp metadata_ingest_enabled? do
    Application.get_env(:drag_n_stamp, :fetch_video_metadata_on_ingest, true)
  end

  defp video_too_long?(%Timestamp{video_duration_seconds: secs} = _timestamp)
       when is_integer(secs) and secs > 40 * 60, do: {:reject, secs}

  defp video_too_long?(%Timestamp{} = timestamp) do
    # Attempt to enrich and persist metadata (caches duration for future attempts)
    updated = ensure_video_metadata(timestamp)

    case updated do
      %Timestamp{video_duration_seconds: secs} when is_integer(secs) and secs > 40 * 60 ->
        {:reject, secs}

      _ ->
        # Fallback: attempt a lightweight duration fetch if metadata ingest is disabled
        case VideoMetadata.extract_video_id(timestamp.url) do
          {:ok, video_id} ->
            case VideoMetadata.fetch_duration_seconds(video_id) do
              {:ok, secs} when is_integer(secs) and secs > 40 * 60 -> {:reject, secs}
              {:ok, _} -> :ok
              {:error, :no_api_key} ->
                Logger.warning("YOUTUBE_DATA_API_KEY not set; skipping duration check for #{timestamp.url}")
                :ok
              {:error, reason} ->
                Logger.debug("Duration check failed (#{inspect(reason)}); proceeding without block")
                :ok
            end

          {:error, reason} ->
            Logger.debug("Could not extract video id (#{inspect(reason)}); proceeding without block")
            :ok
        end
    end
  end

  defp persist_timestamp_signature(%Timestamp{} = timestamp, content) when is_binary(content) do
    signed_content = append_signature(content, submission_slug(timestamp))

    attrs = %{
      content: signed_content,
      processing_status: :ready,
      processing_error: nil
    }

    case Repo.update(Timestamp.changeset(timestamp, attrs)) do
      {:ok, updated} ->
        {updated, signed_content}

      {:error, changeset} ->
        Logger.error(
          "Failed to persist signature on timestamp #{timestamp.id || "new"}: #{inspect(changeset.errors)}"
        )

        {%{timestamp | content: signed_content, processing_status: :ready, processing_error: nil},
         signed_content}
    end
  end

  defp persist_timestamp_signature(%Timestamp{} = timestamp, _content) do
    {timestamp, timestamp.content}
  end

  defp complete_timestamp_generation(conn, api_key, %Timestamp{} = timestamp, content, url) do
    timestamp_with_metadata = ensure_video_metadata(timestamp)

    {timestamp_with_signature, signed_content} =
      persist_timestamp_signature(timestamp_with_metadata, content)

    broadcast_timestamp_updated(timestamp_with_signature)

    Logger.info("Timestamp saved to database for URL: #{url}")

    distill_timestamps(conn, api_key, timestamp_with_signature, signed_content, url)
  end

  defp submission_slug(%Timestamp{id: id} = timestamp) when not is_nil(id) do
    timestamp
    |> PagePath.filename()
    |> Path.rootname()
  end

  defp submission_slug(_), do: nil

  defp append_signature(content, slug) when is_binary(content) do
    trimmed = String.trim_trailing(content)

    signature =
      case slug do
        nil -> "Timestamps by StampBot 🤖"
        slug_value -> "Timestamps by StampBot 🤖\n(#{slug_value})"
      end

    trimmed <> "\n\n" <> signature
  end

  defp append_signature(content, _slug), do: content

  defp process_video_via_captions(
         %Timestamp{} = _timestamp,
         channel_name,
         url,
         api_key,
         opts \\ []
       ) do
    trigger = Keyword.get(opts, :trigger)

    case VideoMetadata.extract_video_id(url) do
      {:ok, video_id} ->
        if api_key in [nil, ""] do
          attempt =
            build_caption_attempt_meta(nil, "failure", maybe_put_trigger(%{
              "reason" => "missing_gemini_api_key",
              "failure_reason" => "missing_api_key",
              "video_url" => url
            }, trigger))

          {:error, :missing_api_key, caption_failure_message(:missing_api_key), attempt}
        else
          case Captions.fetch_transcript(video_id) do
            {:ok, %{segments: segments, context: caption_context}} ->
              case build_transcript_payload(segments) do
                {:ok, transcript_text, stats} ->
                  case summarize_captions(channel_name, transcript_text, api_key) do
                    {:ok, cleaned} ->
                      attempt =
                        build_caption_attempt_meta(video_id, "success", maybe_put_trigger(%{
                          "caption_context" => caption_context,
                          "transcript_stats" => stats,
                          "prompt_character_count" => String.length(transcript_text),
                          "model" => "gemini-2.5-flash",
                          "video_url" => url
                        }, trigger))

                      {:ok, cleaned, attempt}

                    {:error, reason_atom, detail} ->
                      attempt =
                        build_caption_attempt_meta(video_id, "failure", maybe_put_trigger(%{
                          "caption_context" => caption_context,
                          "transcript_stats" => stats,
                          "failure_reason" => Atom.to_string(reason_atom),
                          "detail" => inspect(detail),
                          "video_url" => url
                        }, trigger))

                      {:error, reason_atom, caption_failure_message(reason_atom), attempt}
                  end

                {:error, reason_atom, stats} ->
                  attempt =
                    build_caption_attempt_meta(video_id, "failure", maybe_put_trigger(%{
                      "caption_context" => caption_context,
                      "transcript_stats" => stats,
                      "failure_reason" => Atom.to_string(reason_atom),
                      "video_url" => url
                    }, trigger))

                  {:error, reason_atom, caption_failure_message(reason_atom), attempt}
              end

            {:error, reason, context} ->
              failure_reason = caption_fetch_failure_reason(reason)

              attempt =
                build_caption_attempt_meta(video_id, "failure", maybe_put_trigger(%{
                  "caption_context" => context,
                  "reason" => inspect(reason),
                  "failure_reason" => Atom.to_string(failure_reason),
                  "video_url" => url
                }, trigger))

              {:error, failure_reason, caption_failure_message(failure_reason), attempt}
          end
        end

      {:error, reason} ->
        attempt =
          build_caption_attempt_meta(nil, "failure", maybe_put_trigger(%{
            "reason" => inspect(reason),
            "failure_reason" => "video_id_not_found",
            "video_url" => url
          }, trigger))

        {:error, :video_id_not_found, caption_failure_message(:video_id_not_found), attempt}
    end
  end

  defp summarize_captions(channel_name, transcript_text, api_key) do
    prompt = build_caption_prompt(channel_name, transcript_text)

    case call_gemini_api_text_only(prompt, api_key) do
      {:ok, response} ->
        cond do
          is_binary(response) ->
            cleaned = extract_timestamps_only(response)

            cond do
              is_binary(cleaned) and String.trim(cleaned) != "" ->
                {:ok, String.trim(cleaned)}

              is_binary(cleaned) ->
                {:error, :no_timestamps, response}

              true ->
                {:error, :timestamp_extraction_failed, cleaned}
            end

          true ->
            {:error, :gemini_error, :non_binary_response}
        end

      {:error, reason} ->
        {:error, :gemini_error, reason}
    end
  end

  defp build_caption_prompt(channel_name, transcript_text) do
    trimmed =
      case channel_name do
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
            finalized = finalize_caption_chunk(current_chunk)
            { [finalized | chunks], %{start_ms: start_ms, last_ms: end_ms, texts: [text]} }
          end
      end)

    chunks =
      case current do
        nil -> reversed
        chunk -> [finalize_caption_chunk(chunk) | reversed]
      end

    chunks
    |> Enum.reverse()
    |> Enum.map(fn %{start_ms: start_ms, text: text} ->
      "#{format_caption_time(start_ms)} #{text}"
    end)
  end

  defp finalize_caption_chunk(%{start_ms: start_ms, last_ms: last_ms, texts: texts}) do
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
      :empty_segments -> :captions_empty
      {:invalid_caption_payload, _} -> :captions_fetch_failed
      {:http_error, _} -> :captions_fetch_failed
      {:request_failed, _} -> :captions_fetch_failed
      _ -> :captions_fetch_failed
    end
  end

  defp caption_failure_message(:missing_api_key),
    do:
      "We couldn't access our caption summarizer right now. Please try again later—this video is saved for future analysis."

  defp caption_failure_message(:video_id_not_found),
    do:
      "We couldn't read this YouTube link, so caption summarization is paused. We've saved it for follow-up."

  defp caption_failure_message(:captions_unavailable),
    do:
      "Auto timestamps need captions, and we couldn't find any for this longer video. It's saved so we can re-check later."

  defp caption_failure_message(:captions_empty),
    do:
      "The available captions were empty or unusable, so timestamps aren't ready yet. We've stored this video for review."

  defp caption_failure_message(:captions_fetch_failed),
    do:
      "We hit an issue fetching captions from YouTube. It's logged for future analysis."

  defp caption_failure_message(:transcript_empty),
    do:
      "Captions didn't contain enough usable speech to build timestamps. We'll keep this video on file to retry."

  defp caption_failure_message(:gemini_error),
    do:
      "Gemini had trouble summarizing the captions. We've saved the attempt and will keep an eye on it."

  defp caption_failure_message(:timestamp_extraction_failed),
    do:
      "Gemini responded without clear timestamps. We've saved the output for debugging."

  defp caption_failure_message(:no_timestamps),
    do:
      "Gemini didn't produce usable timestamps from the captions. We'll review this later."

  defp caption_failure_message(_other),
    do:
      "We couldn't create timestamps from captions yet, but the video is stored so we can revisit it."

  defp maybe_put_trigger(map, nil), do: map
  defp maybe_put_trigger(map, trigger), do: Map.put(map, "trigger", trigger)

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

  defp record_caption_attempt(%Timestamp{} = timestamp, attempt_meta) when is_map(attempt_meta) do
    current_context = timestamp.processing_context || %{}
    existing_attempts = Map.get(current_context, "caption_attempts", [])

    new_attempts =
      [attempt_meta | existing_attempts]
      |> Enum.take(@caption_attempt_history_limit)

    summary =
      %{
        "last_result" => Map.get(attempt_meta, "result"),
        "last_reason" =>
          Map.get(attempt_meta, "failure_reason") || Map.get(attempt_meta, "reason"),
        "last_attempt_at" => Map.get(attempt_meta, "at")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    updated_context =
      current_context
      |> Map.put("caption_attempts", new_attempts)
      |> maybe_put_caption_summary(summary)

    case Repo.update(Timestamp.changeset(timestamp, %{processing_context: updated_context})) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("Failed to record caption attempt for #{timestamp.id}: #{inspect(changeset.errors)}")
        %{timestamp | processing_context: updated_context}
    end
  end

  defp record_caption_attempt(%Timestamp{} = timestamp, _), do: timestamp

  defp maybe_put_caption_summary(context, summary) when summary == %{}, do: context
  defp maybe_put_caption_summary(context, summary), do: Map.put(context, "captions_summary", summary)

  defp call_gemini_api_with_retry(prompt, api_key, video_url, attempt \\ 1) do
    case call_gemini_api(prompt, api_key, video_url) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when attempt < 3 ->
        delay = if attempt == 1, do: 5_000, else: 60_000

        Logger.warning(
          "Gemini API attempt #{attempt} failed: #{reason}. Retrying in #{delay}ms..."
        )

        Process.sleep(delay)
        call_gemini_api_with_retry(prompt, api_key, video_url, attempt + 1)

      {:error, reason} ->
        Logger.error("Gemini API failed after #{attempt} attempts: #{reason}")
        {:error, reason}
    end
  end

  defp call_gemini_api(prompt, api_key, video_url) do
    api_url =
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{api_key}"

    headers = [
      {"Content-Type", "application/json"}
    ]

    # Build parts array - always include text prompt
    parts = [%{text: prompt}]

    # Add file_data if video_url is provided
    parts =
      case build_video_part(video_url) do
        nil -> parts
        video_part -> parts ++ [video_part]
      end

    body = %{
      contents: [
        %{
          parts: parts
        }
      ]
    }

    request = Finch.build(:post, api_url, headers, Jason.encode!(body))

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 300_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"candidates" => candidates}} ->
            text = get_in(candidates, [Access.at(0), "content", "parts", Access.at(0), "text"])
            Logger.info("Gemini API raw response: #{inspect(text)}")

            case extract_timestamps_only(text) do
              {:error, reason} ->
                Logger.error("Failed to extract timestamps: #{reason}")
                {:error, "No valid timestamps in response"}

              cleaned_text ->
                Logger.info("Gemini API cleaned timestamps: #{inspect(cleaned_text)}")
                {:ok, cleaned_text}
            end

          {:ok, %{"error" => error}} ->
            {:error, error["message"]}

          {:error, reason} ->
            {:error, "Failed to parse response: #{reason}"}
        end

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}

      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP request failed with status: #{status}"}
    end
  end

  defp build_video_part(nil), do: nil

  defp build_video_part(video_url) when is_binary(video_url) do
    %{file_data: %{file_uri: video_url}}
    #|> Map.put(:videoMetadata, %{"fps" => 0.5})
  end

  defp distill_existing_timestamps(conn, api_key, timestamp, content, url) do
    case distill_timestamps_content(content, api_key) do
      {:ok, distilled_body} ->
        # Update the existing timestamp record with distilled content
        final_content = append_signature(distilled_body, submission_slug(timestamp))
        updated_attrs = %{distilled_content: final_content}

        updated_timestamp =
          case Repo.update(Timestamp.changeset(timestamp, updated_attrs)) do
            {:ok, updated} ->
              updated

            {:error, changeset} ->
              Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
              %{timestamp | distilled_content: final_content}
          end

        broadcast_timestamp_updated(updated_timestamp)

        # Try posting a comment idempotently using the Commenter
        {comment_posted, _comment_status} =
          case DragNStamp.Commenter.post_for_timestamp(updated_timestamp) do
            {:ok, _ts, :ok} ->
              Logger.info("Successfully posted comment to YouTube for URL: #{url}")
              {true, :ok}

            {:ok, _ts, {:skipped, _}} ->
              {false, :skipped}

            {:ok, _ts, {:error, reason}} ->
              Logger.error(
                "Failed to post comment to YouTube for URL: #{url}, reason: #{inspect(reason)}"
              )

              {false, :error}

            other ->
              Logger.error("Unexpected commenter response: #{inspect(other)}")
              {false, :error}
          end

        case updated_timestamp do
          %Timestamp{} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          _ ->
            :ok
        end

        response = %{
          status: "success",
          response: final_content,
          cached: true
        }

        response =
          if comment_posted do
            Map.put(response, :youtube_comment, "posted")
          else
            response
          end

        json(conn, response)

      {:error, reason} ->
        Logger.error("Failed to distill existing timestamps: #{reason}")
        # Fall back to original content
        json(conn, %{
          status: "success",
          response: content,
          cached: true
        })
    end
  end

  defp distill_timestamps(conn, api_key, timestamp, content, url) do
    case distill_timestamps_content(content, api_key) do
      {:ok, distilled_body} ->
        # Update the timestamp record with distilled content
        final_content = append_signature(distilled_body, submission_slug(timestamp))
        updated_attrs = %{distilled_content: final_content}

        updated_timestamp =
          case Repo.update(Timestamp.changeset(timestamp, updated_attrs)) do
            {:ok, updated} ->
              updated

            {:error, changeset} ->
              Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
              %{timestamp | distilled_content: final_content}
          end

        broadcast_timestamp_updated(updated_timestamp)

        # Attempt to post comment via Commenter (first time; idempotent)
        {comment_posted, _comment_status} =
          case DragNStamp.Commenter.post_for_timestamp(updated_timestamp) do
            {:ok, _ts, :ok} ->
              Logger.info("Successfully posted comment to YouTube for URL: #{url}")
              {true, :ok}

            {:ok, _ts, {:skipped, _}} ->
              {false, :skipped}

            {:ok, _ts, {:error, reason}} ->
              Logger.error(
                "Failed to post comment to YouTube for URL: #{url}, reason: #{inspect(reason)}"
              )

              {false, :error}

            other ->
              Logger.error("Unexpected commenter response: #{inspect(other)}")
              {false, :error}
          end

        case updated_timestamp do
          %Timestamp{} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          _ ->
            :ok
        end

        response = %{
          status: "success",
          response: final_content,
          cached: false
        }

        response =
          if comment_posted do
            Map.put(response, :youtube_comment, "posted")
          else
            response
          end

        json(conn, response)

      {:error, reason} ->
        Logger.error("Failed to distill timestamps: #{reason}")
        # Fall back to original content
        json(conn, %{
          status: "success",
          response: content,
          cached: false
        })
    end
  end

  defp distill_timestamps_content(content, api_key) do
    distillation_prompt = """
    You are given a list of timestamps for a YouTube video. Your task is to select only the MOST IMPORTANT timestamps. Secondary goal: try to get timestamps from throughout the whole video.

    1 minute video - 1 timestamp
    [2, 5] minute video - [2, 3] timestamps
    [6, 10] minute video - [6, 8] timestmaps
    [10, 20] minute video - [8, 12] timestamps
    20+ minute video - about (duration / 4) timestamps

    Rules:
    1. Keep only the most significant moments or topics
    3. Preserve the format of the timecode of the timestamps you select
    4. You may update the timestamp text to make the list more engaging
    5. Return only the selected timestamps, nothing else

    <avoid>
      <example>
      0:00 Welcome to GosuCoder: Unveiling the lightning-fast "Sonic" AI model.
      </example>
      <explanation>
      GosuCoder is the channel name, it doesn't really make sense. Don't add an introduction if it isn't in the video.
      </explanation


      <example>
      10:58 The big reveal: Is it Mistral hiding in plain sight?
      </example
      <explanation>
      I want to explore making the timestamps more engaging. The whole mystery of the video in this case was Mistral, so giving it away in text kind of disincentivizes video engagement.
      </explanation>
    </avoid>

    Here are the timestamps to distill:

    #{content}
    """

    case call_gemini_api_text_only(distillation_prompt, api_key) do
      {:ok, response} ->
        Logger.info("Gemini distillation raw response: #{inspect(response)}")

        case extract_timestamps_only(response) do
          {:error, reason} ->
            Logger.error("Failed to extract timestamps from distillation: #{reason}")
            {:error, "No valid timestamps in distillation response"}

          cleaned_response ->
            Logger.info("Gemini distillation cleaned timestamps: #{inspect(cleaned_response)}")
            {:ok, cleaned_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_gemini_api_text_only(prompt, api_key) do
    api_url =
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{api_key}"

    headers = [
      {"Content-Type", "application/json"}
    ]

    body = %{
      contents: [
        %{
          parts: [%{text: prompt}]
        }
      ]
    }

    request = Finch.build(:post, api_url, headers, Jason.encode!(body))

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 300_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"candidates" => candidates}} ->
            text = get_in(candidates, [Access.at(0), "content", "parts", Access.at(0), "text"])
            Logger.info("Gemini text-only API raw response: #{inspect(text)}")
            {:ok, text}

          {:ok, %{"error" => error}} ->
            {:error, error["message"]}

          {:error, reason} ->
            {:error, "Failed to parse response: #{reason}"}
        end

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}

      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP request failed with status: #{status}"}
    end
  end

  # Note: direct posting helper removed in favor of DragNStamp.Commenter
end
