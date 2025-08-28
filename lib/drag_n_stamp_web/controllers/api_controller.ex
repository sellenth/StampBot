defmodule DragNStampWeb.ApiController do
  use DragNStampWeb, :controller
  require Logger
  alias DragNStamp.{Repo, Timestamp, YouTubeAPI}

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

    # Check if we already have timestamps for this URL
    case Repo.get_by(Timestamp, url: url) do
      %Timestamp{distilled_content: distilled_content} when not is_nil(distilled_content) ->
        Logger.info("Found existing distilled timestamps for URL: #{url}")

        json(conn, %{
          status: "success",
          response: distilled_content,
          cached: true
        })

      %Timestamp{content: content} = timestamp ->
        Logger.info(
          "Found existing timestamps but no distilled version for URL: #{url}, distilling..."
        )

        distill_existing_timestamps(conn, api_key, timestamp, content, url)

      nil ->
        Logger.info("No existing timestamps found for URL: #{url}, calling Gemini API")
        generate_new_timestamps(conn, api_key, channel_name, submitter_username, url)
    end
  end

  defp generate_new_timestamps(conn, api_key, channel_name, submitter_username, url) do
    # Create the formatted prompt for timestamps
    formatted_prompt =
      "give me timestamps every few minutes of the important parts of this video. use 8-12 words per timestamp. structure your response as a youtube description. here's the link, be slightly humorous but not too much ;) channel name is #{channel_name}. put each timestmap on its own line, no indentation, no extra lines between, NO EXTRA COMMENTARY BESIDES THE TIMESTMAPS.

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

    if api_key do
      case call_gemini_api_with_retry(formatted_prompt, api_key, url) do
        {:ok, response} ->
          # Save timestamp to database
          timestamp_attrs = %{
            url: url,
            channel_name: channel_name,
            submitter_username: submitter_username,
            content: response
          }

          case Repo.insert(Timestamp.changeset(%Timestamp{}, timestamp_attrs)) do
            {:ok, timestamp} ->
              Logger.info("Timestamp saved to database for URL: #{url}")
              # Broadcast the new timestamp for LiveView updates
              Phoenix.PubSub.broadcast(
                DragNStamp.PubSub,
                "timestamps",
                {:timestamp_created, timestamp}
              )

              # Now distill the timestamps
              distill_timestamps(conn, api_key, timestamp, response, url)

            {:error, changeset} ->
              Logger.error("Failed to save timestamp: #{inspect(changeset.errors)}")

              json(conn, %{
                status: "success",
                response: response,
                cached: false
              })
          end

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            status: "error",
            message: "Failed to get response from Gemini API after retries: #{reason}"
          })
      end
    else
      conn
      |> put_status(:internal_server_error)
      |> json(%{
        status: "error",
        message: "GEMINI_API_KEY environment variable not set"
      })
    end
  end

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
      if video_url do
        parts ++ [%{file_data: %{file_uri: video_url}}]
      else
        parts
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
                final_text = cleaned_text <> "\n\nTimestamps by StampBot 🤖"
                Logger.info("Gemini API final processed text: #{inspect(final_text)}")
                {:ok, final_text}
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

  defp distill_existing_timestamps(conn, api_key, timestamp, content, url) do
    case distill_timestamps_content(content, api_key) do
      {:ok, distilled_content} ->
        # Update the existing timestamp record and auto-post comment
        updated_attrs = %{distilled_content: distilled_content}
        
        # Check if we should post a comment (only if not posted yet)
        {updated_attrs, comment_posted} = if not timestamp.youtube_comment_posted do
          case post_to_youtube(url, distilled_content) do
            {:ok, _} -> 
              Logger.info("Successfully posted comment to YouTube for URL: #{url}")
              {Map.put(updated_attrs, :youtube_comment_posted, true), true}
            {:error, reason} ->
              Logger.error("Failed to post comment to YouTube for URL: #{url}, reason: #{reason}")
              {updated_attrs, false}
          end
        else
          Logger.info("Comment already posted for URL: #{url}, skipping")
          {updated_attrs, false}
        end
        
        case Repo.update(Timestamp.changeset(timestamp, updated_attrs)) do
          {:ok, _updated_timestamp} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          {:error, changeset} ->
            Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
        end

        response = %{
          status: "success",
          response: distilled_content,
          cached: true
        }
        
        response = if comment_posted do
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
      {:ok, distilled_content} ->
        # Update the timestamp record with distilled content and auto-post comment
        updated_attrs = %{distilled_content: distilled_content}
        
        # Always post a comment for new distilled timestamps (this is the first distillation)
        {updated_attrs, comment_posted} = case post_to_youtube(url, distilled_content) do
          {:ok, _} -> 
            Logger.info("Successfully posted comment to YouTube for URL: #{url}")
            {Map.put(updated_attrs, :youtube_comment_posted, true), true}
          {:error, reason} ->
            Logger.error("Failed to post comment to YouTube for URL: #{url}, reason: #{reason}")
            {updated_attrs, false}
        end
        
        case Repo.update(Timestamp.changeset(timestamp, updated_attrs)) do
          {:ok, _updated_timestamp} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          {:error, changeset} ->
            Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
        end

        response = %{
          status: "success",
          response: distilled_content,
          cached: false
        }

        response = if comment_posted do
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
    You are given a list of timestamps for a YouTube video. Your task is to select only the 10 MOST IMPORTANT timestamps. If there are fewer than 10, list them all. Secondary goal: try to get timestamps from throughout the whole video.

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
            final_response = cleaned_response <> "\n\nTimestamps by StampBot 🤖"
            Logger.info("Gemini distillation final processed text: #{inspect(final_response)}")
            {:ok, final_response}
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

  defp post_to_youtube(url, content) do
    case YouTubeAPI.post_comment(url, content) do
      {:ok, response} ->
        Logger.info("Successfully posted comment to YouTube for URL: #{url}")
        {:ok, response}
      
      {:error, reason} ->
        Logger.error("Failed to post comment to YouTube for URL: #{url}, reason: #{reason}")
        {:error, reason}
    end
  end
end
