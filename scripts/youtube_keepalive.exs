#!/usr/bin/env elixir

# YouTube OAuth keepalive: refresh access token using existing refresh token
# Usage: mix run scripts/youtube_keepalive.exs

defmodule YouTubeKeepAlive do
  @moduledoc """
  Simple keepalive for YouTube OAuth credentials.
  - Uses `YOUTUBE_REFRESH_TOKEN`, `YOUTUBE_CLIENT_ID`, `YOUTUBE_CLIENT_SECRET`
  - Exchanges refresh token for an access token
  - Calls a lightweight YouTube endpoint to keep credentials active
  """

  require Logger

  @token_url "https://oauth2.googleapis.com/token"
  @test_api_url "https://www.googleapis.com/youtube/v3/channels?part=id&mine=true"

  def run do
    IO.puts("\n🔄 YouTube OAuth keepalive")

    with {:ok, creds} <- read_env(),
         {:ok, access_token} <- refresh_access_token(creds),
         :ok <- test_api(access_token) do
      IO.puts("\n✅ Keepalive complete: token refreshed and API reachable")
      :ok
    else
      {:error, reason} ->
        IO.puts("\n❌ Keepalive failed: #{reason}")
        System.halt(1)
    end
  end

  defp read_env do
    case {
           System.get_env("YOUTUBE_REFRESH_TOKEN"),
           System.get_env("YOUTUBE_CLIENT_ID"),
           System.get_env("YOUTUBE_CLIENT_SECRET")
         } do
      {nil, _, _} -> {:error, "YOUTUBE_REFRESH_TOKEN not set"}
      {_, nil, _} -> {:error, "YOUTUBE_CLIENT_ID not set"}
      {_, _, nil} -> {:error, "YOUTUBE_CLIENT_SECRET not set"}
      {rt, id, secret} -> {:ok, %{refresh_token: rt, client_id: id, client_secret: secret}}
    end
  end

  defp refresh_access_token(%{refresh_token: rt, client_id: id, client_secret: secret}) do
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]
    body =
      URI.encode_query(%{
        "client_id" => id,
        "client_secret" => secret,
        "refresh_token" => rt,
        "grant_type" => "refresh_token"
      })

    request = Finch.build(:post, @token_url, headers, body)

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"access_token" => at}} -> {:ok, at}
          _ -> {:error, "Could not parse token response"}
        end
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "Token refresh failed (#{status}): #{body}"}
      {:error, reason} ->
        {:error, "Token refresh request error: #{inspect(reason)}"}
    end
  end

  defp test_api(access_token) do
    headers = [{"Authorization", "Bearer #{access_token}"}, {"Content-Type", "application/json"}]
    request = Finch.build(:get, @test_api_url, headers)
    case Finch.request(request, DragNStamp.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200}} -> :ok
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "YouTube API check failed (#{status}): #{body}"}
      {:error, reason} -> {:error, "YouTube API request error: #{inspect(reason)}"}
    end
  end
end

YouTubeKeepAlive.run()

