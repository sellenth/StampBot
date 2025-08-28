defmodule DragNStamp.YouTubeAPI do
  @moduledoc """
  Client for YouTube Data API v3 operations.
  Handles commenting on YouTube videos using system OAuth credentials.
  """

  require Logger

  @youtube_api_base "https://www.googleapis.com/youtube/v3"
  @oauth_token_url "https://oauth2.googleapis.com/token"

  @doc """
  Posts a comment to a YouTube video using the system's OAuth token.
  
  ## Parameters
  - video_url: The YouTube video URL
  - comment_text: The comment content to post
  
  ## Returns
  - {:ok, response} on success
  - {:error, reason} on failure
  """
  def post_comment(video_url, comment_text) do
    with {:ok, video_id} <- extract_video_id(video_url),
         {:ok, access_token} <- get_valid_access_token() do
      create_comment_thread(video_id, comment_text, access_token)
    end
  end

  defp extract_video_id(url) when is_binary(url) do
    cond do
      # youtube.com/watch?v=VIDEO_ID
      String.contains?(url, "youtube.com/watch") ->
        case Regex.run(~r/[?&]v=([^&]+)/, url) do
          [_, video_id] -> {:ok, video_id}
          _ -> {:error, "Could not extract video ID from YouTube URL"}
        end

      # youtu.be/VIDEO_ID
      String.contains?(url, "youtu.be/") ->
        case Regex.run(~r/youtu\.be\/([^?&]+)/, url) do
          [_, video_id] -> {:ok, video_id}
          _ -> {:error, "Could not extract video ID from youtu.be URL"}
        end

      true ->
        {:error, "Invalid YouTube URL format"}
    end
  end

  defp get_valid_access_token do
    access_token = System.get_env("YOUTUBE_ACCESS_TOKEN")
    
    case access_token do
      nil ->
        {:error, "YOUTUBE_ACCESS_TOKEN not configured"}
      
      token ->
        # Try using the token first, refresh if needed
        case test_token_validity(token) do
          :valid -> 
            {:ok, token}
          
          :invalid ->
            Logger.info("YouTube access token expired, attempting refresh")
            refresh_access_token()
        end
    end
  end

  defp test_token_validity(token) do
    # Make a simple API call to test if token is valid
    url = "#{@youtube_api_base}/channels?part=id&mine=true"
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:get, url, headers)
    
    case Finch.request(request, DragNStamp.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200}} ->
        :valid
      
      {:ok, %Finch.Response{status: 401}} ->
        :invalid
      
      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("Unexpected status #{status} when testing YouTube token")
        :invalid
      
      {:error, reason} ->
        Logger.error("Failed to test YouTube token: #{inspect(reason)}")
        :invalid
    end
  end

  defp refresh_access_token do
    refresh_token = System.get_env("YOUTUBE_REFRESH_TOKEN")
    client_id = System.get_env("YOUTUBE_CLIENT_ID")
    client_secret = System.get_env("YOUTUBE_CLIENT_SECRET")

    case {refresh_token, client_id, client_secret} do
      {nil, _, _} ->
        {:error, "YOUTUBE_REFRESH_TOKEN not configured"}
      
      {_, nil, _} ->
        {:error, "YOUTUBE_CLIENT_ID not configured"}
      
      {_, _, nil} ->
        {:error, "YOUTUBE_CLIENT_SECRET not configured"}
      
      {refresh_token, client_id, client_secret} ->
        perform_token_refresh(refresh_token, client_id, client_secret)
    end
  end

  defp perform_token_refresh(refresh_token, client_id, client_secret) do
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]
    
    body = URI.encode_query(%{
      "client_id" => client_id,
      "client_secret" => client_secret,
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    })

    request = Finch.build(:post, @oauth_token_url, headers, body)

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"access_token" => new_access_token}} ->
            Logger.info("Successfully refreshed YouTube access token")
            # Note: In production, you'd want to update the stored token
            # For now, we'll just return it for this request
            {:ok, new_access_token}
          
          {:error, reason} ->
            Logger.error("Failed to parse token refresh response: #{reason}")
            {:error, "Failed to parse token refresh response"}
        end
      
      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.error("Token refresh failed with status #{status}: #{body}")
        {:error, "Token refresh failed"}
      
      {:error, reason} ->
        Logger.error("Token refresh request failed: #{inspect(reason)}")
        {:error, "Token refresh request failed"}
    end
  end

  defp create_comment_thread(video_id, comment_text, access_token) do
    url = "#{@youtube_api_base}/commentThreads?part=snippet"
    
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "snippet" => %{
        "videoId" => video_id,
        "topLevelComment" => %{
          "snippet" => %{
            "textOriginal" => comment_text
          }
        }
      }
    }

    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, response} ->
            Logger.info("Successfully posted comment to YouTube video #{video_id}")
            {:ok, response}
          
          {:error, reason} ->
            Logger.error("Failed to parse comment response: #{reason}")
            {:error, "Failed to parse response"}
        end
      
      {:ok, %Finch.Response{status: 403, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"message" => message}}} ->
            Logger.error("YouTube API quota/permission error: #{message}")
            {:error, "Quota exceeded or insufficient permissions: #{message}"}
          
          _ ->
            Logger.error("YouTube API 403 error: #{body}")
            {:error, "Permission denied or quota exceeded"}
        end
      
      {:ok, %Finch.Response{status: 400, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"message" => message}}} ->
            Logger.error("YouTube API bad request: #{message}")
            {:error, "Bad request: #{message}"}
          
          _ ->
            Logger.error("YouTube API 400 error: #{body}")
            {:error, "Bad request"}
        end
      
      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.error("YouTube API error #{status}: #{body}")
        {:error, "API request failed with status #{status}"}
      
      {:error, reason} ->
        Logger.error("YouTube API request failed: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end