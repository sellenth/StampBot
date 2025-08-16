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

  def gemini(conn, params) do
    api_key = System.get_env("GEMINI_API_KEY")
    channel_name = Map.get(params, "channel_name", "anonymous")
    username = Map.get(params, "username", "anonymous")
    submitter_username = Map.get(params, "submitter_username", "anonymous")
    url = Map.get(params, "url")

    Logger.info("Gemini request - Channel: #{channel_name}, Username: #{username}, Submitter: #{submitter_username}, URL: #{url}")

    # Create the formatted prompt for timestamps
    formatted_prompt =
      "give me timestamps every few minutes of the important parts of this video. use 8-12 words per timestamp. structure your response as a youtube description. here's the link, be slightly humorous but not too much ;) channel name is #{channel_name}. put each timestmap on its own line, no indentation, no extra lines between, no extra commentary besides the timestmaps"

    if api_key do
      case call_gemini_api(formatted_prompt, api_key, url) do
        {:ok, response} ->
          # Save timestamp to database
          timestamp_attrs = %{
            url: url,
            channel_name: channel_name,
            username: username,
            submitter_username: submitter_username,
            content: response
          }
          
          case Repo.insert(Timestamp.changeset(%Timestamp{}, timestamp_attrs)) do
            {:ok, _timestamp} ->
              Logger.info("Timestamp saved to database for URL: #{url}")
            {:error, changeset} ->
              Logger.error("Failed to save timestamp: #{inspect(changeset.errors)}")
          end
          
          json(conn, %{
            status: "success",
            response: response
          })

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
