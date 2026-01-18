defmodule DragNStampWeb.ApiController do
  use DragNStampWeb, :controller
  require Logger
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.{PagePath, VideoMetadata}
  alias DragNStamp.Timestamps.Parser
  alias DragNStamp.Timestamps.GeminiClient
  alias DragNStamp.Timestamps.CaptionFallback

  @caption_attempt_history_limit 5

  @doc """
  Re-run the full generation + distillation flow for an existing Timestamp.
  Acquires the same URL lock and reuses the standard pipeline.
  Intended for one-off manual retries triggered from the UI.
  """
  def reprocess_timestamp(%Timestamp{} = existing) do
    api_key = System.get_env("GEMINI_API_KEY")
    url = existing.url |> normalize_youtube_url()

    case acquire_url_lock(url) do
      :acquired ->
        try do
          conn = Plug.Test.conn(:post, "/api/gemini")

          # Use existing record to avoid creating duplicates; this will
          # update it to :processing and proceed through the pipeline.
          generate_new_timestamps(
            conn,
            api_key,
            existing.channel_name || "anonymous",
            existing.submitter_username || "anonymous",
            url,
            existing
          )
        after
          release_url_lock(url)
        end

        :ok

      :in_flight ->
        Logger.info("Reprocess skipped; lock already held for URL: #{url}")
        {:error, :in_flight}
    end
  end

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

      If you are provided input that seems missing the content, do no make up timestamps. Just put '0:00 UNWATCHED' so our support agent can handle the submission.

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

      case video_processing_plan(timestamp) do
        {:captions, seconds} ->
          Logger.info(
            "Video exceeds 20-minute limit (#{seconds}s). Attempting caption-based processing."
          )

          case CaptionFallback.process(channel_name, url, api_key, trigger: "length_gate") do
            {:ok, cleaned, attempt_meta} ->
              attempt_meta =
                attempt_meta
                |> Map.put_new("video_seconds", seconds)

              updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

              Logger.info("Caption-based pipeline succeeded for long video #{url}")

              complete_timestamp_generation(
                conn,
                api_key,
                updated_timestamp,
                cleaned,
                url,
                Map.get(attempt_meta, "model")
              )

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
                max_minutes: 20,
                video_minutes: minutes,
                fallback: "captions"
              })
          end

        {:vlm, plan_opts} ->
          generation_config = Map.get(plan_opts, :generation_config)
          video_seconds = Map.get(plan_opts, :seconds)
          gemini_opts = build_gemini_opts(generation_config)

          if generation_config do
            Logger.info(
              "Requesting Gemini video+ timestamps with #{generation_config["mediaResolution"]} for #{url}"
            )
          end

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
            case GeminiClient.timestamps_with_retry(formatted_prompt, api_key, url, gemini_opts) do
              {:ok, generated_content, model} ->
                complete_timestamp_generation(
                  conn,
                  api_key,
                  timestamp,
                  generated_content,
                  url,
                  model
                )

              {:error, reason} ->
                Logger.warning(
                  "Gemini video+ request failed with #{inspect(reason)}. Falling back to captions for #{url}"
                )

                case CaptionFallback.process(
                       channel_name,
                       url,
                       api_key,
                       trigger: "vlm_failure"
                     ) do
                  {:ok, cleaned, attempt_meta} ->
                    attempt_meta =
                      attempt_meta
                      |> Map.put_new("vlm_error", inspect(reason))
                      |> maybe_put_resolution_meta(generation_config)
                      |> maybe_put_video_seconds(video_seconds)

                    updated_timestamp = record_caption_attempt(timestamp, attempt_meta)

                    Logger.info("Caption-based fallback succeeded after VLM failure for #{url}")

                    complete_timestamp_generation(
                      conn,
                      api_key,
                      updated_timestamp,
                      cleaned,
                      url,
                      Map.get(attempt_meta, "model")
                    )

                  {:error, fallback_reason, friendly_message, attempt_meta} ->
                    attempt_meta =
                      attempt_meta
                      |> Map.put_new("vlm_error", inspect(reason))
                      |> maybe_put_resolution_meta(generation_config)
                      |> maybe_put_video_seconds(video_seconds)

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

  defp build_gemini_opts(nil), do: []
  defp build_gemini_opts(config) when is_map(config), do: [generation_config: config]

  defp maybe_put_resolution_meta(attempt_meta, nil), do: attempt_meta

  defp maybe_put_resolution_meta(attempt_meta, config) when is_map(config) do
    resolution = Map.get(config, "mediaResolution", "MEDIA_RESOLUTION_UNSPECIFIED")

    case attempt_meta do
      %{} = meta -> Map.put_new(meta, "vlm_media_resolution", resolution)
      _ -> attempt_meta
    end
  end

  defp maybe_put_video_seconds(attempt_meta, nil), do: attempt_meta

  defp maybe_put_video_seconds(attempt_meta, seconds) when is_integer(seconds) do
    case attempt_meta do
      %{} = meta -> Map.put_new(meta, "video_seconds", seconds)
      _ -> attempt_meta
    end
  end

  defp maybe_put_video_seconds(attempt_meta, _), do: attempt_meta

  defp video_processing_plan(%Timestamp{video_duration_seconds: secs}) when is_integer(secs) do
    classify_video_plan(secs)
  end

  defp video_processing_plan(%Timestamp{} = timestamp) do
    updated = ensure_video_metadata(timestamp)

    case updated do
      %Timestamp{video_duration_seconds: secs} when is_integer(secs) ->
        classify_video_plan(secs)

      _ ->
        case VideoMetadata.extract_video_id(timestamp.url) do
          {:ok, video_id} ->
            case VideoMetadata.fetch_duration_seconds(video_id) do
              {:ok, secs} when is_integer(secs) ->
                classify_video_plan(secs)

              {:ok, _unknown} ->
                {:vlm, %{seconds: nil, generation_config: nil}}

              {:error, :no_api_key} ->
                Logger.warning(
                  "YOUTUBE_DATA_API_KEY not set; skipping duration check for #{timestamp.url}"
                )

                {:vlm, %{seconds: nil, generation_config: nil}}

              {:error, reason} ->
                Logger.debug(
                  "Duration check failed (#{inspect(reason)}); proceeding without block"
                )

                {:vlm, %{seconds: nil, generation_config: nil}}
            end

          {:error, reason} ->
            Logger.debug(
              "Could not extract video id (#{inspect(reason)}); proceeding without block"
            )

            {:vlm, %{seconds: nil, generation_config: nil}}
        end
    end
  end

  defp classify_video_plan(seconds) when is_integer(seconds) do
    cond do
      seconds > 20 * 60 ->
        {:captions, seconds}

      true ->
        {:vlm,
         %{
           seconds: seconds,
           generation_config: %{"mediaResolution" => "MEDIA_RESOLUTION_LOW"}
         }}
    end
  end

  defp persist_timestamp_signature(%Timestamp{} = timestamp, content, model) when is_binary(content) do
    signed_content = append_signature(content, submission_slug(timestamp))

    attrs = %{
      content: signed_content,
      processing_status: :ready,
      processing_error: nil
    }

    attrs =
      if model do
        context = timestamp.processing_context || %{}
        Map.put(attrs, :processing_context, Map.put(context, "generation_model", model))
      else
        attrs
      end

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

  defp persist_timestamp_signature(%Timestamp{} = timestamp, _content, _model) do
    {timestamp, timestamp.content}
  end

  defp complete_timestamp_generation(conn, api_key, %Timestamp{} = timestamp, content, url, model) do
    timestamp_with_metadata = ensure_video_metadata(timestamp)

    {timestamp_with_signature, signed_content} =
      persist_timestamp_signature(timestamp_with_metadata, content, model)

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
        Logger.error(
          "Failed to record caption attempt for #{timestamp.id}: #{inspect(changeset.errors)}"
        )

        %{timestamp | processing_context: updated_context}
    end
  end

  defp record_caption_attempt(%Timestamp{} = timestamp, _), do: timestamp

  defp maybe_put_caption_summary(context, summary) when summary == %{}, do: context

  defp maybe_put_caption_summary(context, summary),
    do: Map.put(context, "captions_summary", summary)

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
    You are given a list of timestamps for a YouTube video. Your task is to select the most important timestamps. Secondary goal: try to get timestamps from throughout the whole video.

    1 minute video - 1 timestamp
    [2, 5] minute video - [2, 3] timestamps
    [6, 10] minute video - [6, 8] timestmaps
    [10, 20] minute video - [8, 12] timestamps
    For videos longer than that, really focus on getting timestamps from all throughout the video. If there's a bunching of 2+ timestamps within a 60 second period, try to combine them into one timestamp.

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

    case GeminiClient.text_only(distillation_prompt, api_key) do
      {:ok, response, _model} ->
        Logger.info("Gemini distillation raw response: #{inspect(response)}")

        case Parser.extract_timestamps_only(response) do
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

  # Note: direct posting helper removed in favor of DragNStamp.Commenter
end
