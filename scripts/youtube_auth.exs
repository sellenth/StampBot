#!/usr/bin/env elixir

# YouTube OAuth 2.0 Authentication Script for StampBot
# Usage: mix run scripts/youtube_auth.exs

defmodule YouTubeAuth do
  @moduledoc """
  Interactive YouTube OAuth 2.0 authentication helper.
  Guides through the OAuth flow and saves refresh token to .env file.
  """

  @oauth_base_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @test_api_url "https://www.googleapis.com/youtube/v3/channels?part=id&mine=true"

  def run do
    IO.puts("\n🔐 YouTube OAuth 2.0 Authentication for StampBot")
    IO.puts("=" |> String.duplicate(50))

    with {:ok, credentials} <- get_credentials(),
         {:ok, auth_url} <- generate_auth_url(credentials),
         {:ok, code} <- get_authorization_code(auth_url),
         {:ok, tokens} <- exchange_code_for_tokens(code, credentials),
         :ok <- update_env_file(tokens["refresh_token"]),
         :ok <- test_tokens(tokens["access_token"]) do
      
      IO.puts("\n✅ YouTube authentication completed successfully!")
      IO.puts("🚀 You can now use auto-commenting features in StampBot")
    else
      {:error, reason} ->
        IO.puts("\n❌ Authentication failed: #{reason}")
        System.halt(1)
    end
  end

  defp get_credentials do
    IO.puts("\n📋 Reading OAuth credentials from environment...")
    
    client_id = System.get_env("YOUTUBE_CLIENT_ID")
    client_secret = System.get_env("YOUTUBE_CLIENT_SECRET")

    case {client_id, client_secret} do
      {nil, _} ->
        {:error, "YOUTUBE_CLIENT_ID not found in environment"}
      
      {_, nil} ->
        {:error, "YOUTUBE_CLIENT_SECRET not found in environment"}
      
      {client_id, client_secret} ->
        IO.puts("✅ Found OAuth credentials")
        {:ok, %{client_id: client_id, client_secret: client_secret}}
    end
  end

  defp generate_auth_url(credentials) do
    params = %{
      "client_id" => credentials.client_id,
      "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob",
      "response_type" => "code",
      "scope" => "https://www.googleapis.com/auth/youtube.force-ssl",
      "access_type" => "offline",
      "prompt" => "consent"
    }

    query_string = URI.encode_query(params)
    auth_url = "#{@oauth_base_url}?#{query_string}"
    
    {:ok, auth_url}
  end

  defp get_authorization_code(auth_url) do
    IO.puts("\n🌐 Step 1: Authorize StampBot to access YouTube")
    IO.puts("=" |> String.duplicate(45))
    IO.puts("📱 Open this URL in your browser:")
    IO.puts(auth_url)
    IO.puts("\n📋 After authorization, you'll see a code.")
    IO.puts("Copy the authorization code and paste it below.")
    
    IO.write("\n🔑 Enter authorization code: ")
    
    case IO.gets("") do
      :eof ->
        {:error, "No input provided"}
      
      input ->
        case String.trim(input) do
          "" ->
            {:error, "Authorization code cannot be empty"}
          
          code ->
            {:ok, code}
        end
    end
  end

  defp exchange_code_for_tokens(code, credentials) do
    IO.puts("\n🔄 Step 2: Exchanging authorization code for tokens...")
    
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]
    
    body = URI.encode_query(%{
      "client_id" => credentials.client_id,
      "client_secret" => credentials.client_secret,
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
    })

    request = Finch.build(:post, @token_url, headers, body)
    
    case Finch.request(request, DragNStamp.Finch) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, tokens} ->
            IO.puts("✅ Successfully obtained tokens")
            {:ok, tokens}
          
          {:error, _} ->
            {:error, "Failed to parse token response"}
        end
      
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "Token exchange failed with status #{status}: #{body}"}
      
      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp update_env_file(refresh_token) do
    IO.puts("\n💾 Step 3: Updating .env file...")
    
    env_file = ".env"
    
    case File.read(env_file) do
      {:ok, content} ->
        updated_content = 
          if String.contains?(content, "YOUTUBE_REFRESH_TOKEN=") do
            String.replace(content, ~r/YOUTUBE_REFRESH_TOKEN=.*/, "YOUTUBE_REFRESH_TOKEN=#{refresh_token}")
          else
            content <> "\nYOUTUBE_REFRESH_TOKEN=#{refresh_token}"
          end
        
        case File.write(env_file, updated_content) do
          :ok ->
            IO.puts("✅ Updated .env file with refresh token")
            :ok
          
          {:error, reason} ->
            IO.puts("⚠️  Could not update .env file: #{reason}")
            IO.puts("Please manually add this line to your .env file:")
            IO.puts("YOUTUBE_REFRESH_TOKEN=#{refresh_token}")
            :ok
        end
      
      {:error, _} ->
        IO.puts("⚠️  Could not read .env file")
        IO.puts("Please manually add this line to your .env file:")
        IO.puts("YOUTUBE_REFRESH_TOKEN=#{refresh_token}")
        :ok
    end
  end

  defp test_tokens(access_token) do
    IO.puts("\n🧪 Step 4: Testing token validity...")
    
    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:get, @test_api_url, headers)
    
    case Finch.request(request, DragNStamp.Finch) do
      {:ok, %Finch.Response{status: 200}} ->
        IO.puts("✅ Tokens are valid and YouTube API is accessible")
        :ok
      
      {:ok, %Finch.Response{status: 401}} ->
        IO.puts("⚠️  Token test failed - tokens may be invalid")
        IO.puts("However, the refresh token should still work for future requests")
        :ok
      
      {:ok, %Finch.Response{status: status}} ->
        IO.puts("⚠️  Token test returned status #{status}")
        IO.puts("This may be normal - the refresh token should still work")
        :ok
      
      {:error, reason} ->
        IO.puts("⚠️  Could not test tokens: #{inspect(reason)}")
        IO.puts("This may be normal - the refresh token should still work")
        :ok
    end
  end
end

# Load environment variables if .env exists
if File.exists?(".env") do
  File.stream!(".env")
  |> Enum.each(fn line ->
    case String.trim(line) do
      "#" <> _ -> :ignore  # Skip comments
      "" -> :ignore       # Skip empty lines
      line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            System.put_env(key, value)
          _ ->
            :ignore
        end
    end
  end)
end

# Run the authentication flow
YouTubeAuth.run()