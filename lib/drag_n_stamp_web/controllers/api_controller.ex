defmodule DragNStampWeb.ApiController do
  use DragNStampWeb, :controller
  require Logger
  alias DragNStamp.{Repo, Timestamp}

  def receive_url(conn, %{"url" => url} = params) do
    username = Map.get(params, "username", "anonymous")
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
      
      true -> url
    end
  end

  defp extract_timestamps_only(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line ->
      # Match lines that start with timestamp pattern like "0:00", "1:23", "12:34", etc.
      String.match?(line, ~r/^\s*\d+:\d+/)
    end)
    |> Enum.join("\n")
  end

  def gemini(conn, params) do
    api_key = System.get_env("GEMINI_API_KEY")
    channel_name = Map.get(params, "channel_name", "anonymous")
    submitter_username = Map.get(params, "submitter_username", "anonymous")
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
        Logger.info("Found existing timestamps but no distilled version for URL: #{url}, distilling...")
        distill_existing_timestamps(conn, api_key, timestamp, content)

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
      "

    if api_key do
      case call_gemini_api(formatted_prompt, api_key, url) do
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
              # Now distill the timestamps
              distill_timestamps(conn, api_key, timestamp, response)

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
            message: "Failed to get response from Gemini API: #{reason}"
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
            cleaned_text = extract_timestamps_only(text)
            final_text = cleaned_text <> "\n\nTimestamps by McCoder Douglas"
            {:ok, final_text}

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

  defp distill_existing_timestamps(conn, api_key, timestamp, content) do
    case distill_timestamps_content(content, api_key) do
      {:ok, distilled_content} ->
        # Update the existing timestamp record
        case Repo.update(Timestamp.changeset(timestamp, %{distilled_content: distilled_content})) do
          {:ok, _updated_timestamp} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          {:error, changeset} ->
            Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
        end

        json(conn, %{
          status: "success",
          response: distilled_content,
          cached: true
        })

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

  defp distill_timestamps(conn, api_key, timestamp, content) do
    case distill_timestamps_content(content, api_key) do
      {:ok, distilled_content} ->
        # Update the timestamp record with distilled content
        case Repo.update(Timestamp.changeset(timestamp, %{distilled_content: distilled_content})) do
          {:ok, _updated_timestamp} ->
            Logger.info("Distilled timestamps saved to database for URL: #{timestamp.url}")

          {:error, changeset} ->
            Logger.error("Failed to save distilled timestamps: #{inspect(changeset.errors)}")
        end

        json(conn, %{
          status: "success",
          response: distilled_content,
          cached: false
        })

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
    You are given a list of timestamps for a YouTube video. Your task is to select only the MOST IMPORTANT timestamps, aiming for approximately 1 timestamp per 90 seconds of video content.

    Rules:
    1. Keep only the most significant moments or topics
    2. Aim for no more than 1 timestamp per 90 seconds
    3. Preserve the exact format of the timestamps you select
    4. Do not modify the text of the selected timestamps
    5. Return only the selected timestamps, nothing else

    Here are the timestamps to distill:

    #{content}
    """

    case call_gemini_api_text_only(distillation_prompt, api_key) do
      {:ok, response} ->
        cleaned_response = extract_timestamps_only(response)
        final_response = cleaned_response <> "\n\nTimestamps by McCoder Douglas"
        {:ok, final_response}

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
end
