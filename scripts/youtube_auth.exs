#!/usr/bin/env elixir

# YouTube OAuth 2.0 Authentication Script for StampBot
# Usage: mix run scripts/youtube_auth.exs

defmodule YouTubeAuth do
  @moduledoc """
  Interactive YouTube OAuth 2.0 authentication helper.
  Uses loopback redirect (local HTTP server) for OAuth flow.
  """

  @oauth_base_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @test_api_url "https://www.googleapis.com/youtube/v3/channels?part=id&mine=true"
  @redirect_port 8089
  @redirect_uri "http://localhost:8089/callback"

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
        IO.puts("\n💡 Common solutions:")
        IO.puts("   • Verify your YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET are correct")
        IO.puts("   • Check that your Google Cloud project has YouTube Data API enabled")
        IO.puts("   • Ensure the OAuth consent screen is properly configured")
        IO.puts("   • Make sure http://localhost:8089/callback is in your OAuth redirect URIs")
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
      "redirect_uri" => @redirect_uri,
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
    IO.puts("Starting local server on port #{@redirect_port}...")

    # Start a simple TCP server to receive the OAuth callback
    {:ok, listen_socket} = :gen_tcp.listen(@redirect_port, [
      :binary,
      packet: :http_bin,
      active: false,
      reuseaddr: true
    ])

    IO.puts("✅ Local server started")
    IO.puts("\n📱 Open this URL in your browser:")
    IO.puts(auth_url)
    IO.puts("\n⏳ Waiting for authorization callback...")

    result = receive_authorization_code(listen_socket)
    :gen_tcp.close(listen_socket)
    result
  end

  defp receive_authorization_code(listen_socket) do
    case :gen_tcp.accept(listen_socket, 120_000) do
      {:ok, client_socket} ->
        case read_http_request(client_socket, nil) do
          {:ok, code} ->
            # Send success response to browser
            response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html\r
            Connection: close\r
            \r
            <html><body style="font-family: sans-serif; text-align: center; padding-top: 50px;">
            <h1>✅ Authorization Successful!</h1>
            <p>You can close this window and return to the terminal.</p>
            </body></html>
            """
            :gen_tcp.send(client_socket, response)
            :gen_tcp.close(client_socket)
            {:ok, code}

          {:error, reason} ->
            # Send error response to browser
            response = """
            HTTP/1.1 400 Bad Request\r
            Content-Type: text/html\r
            Connection: close\r
            \r
            <html><body style="font-family: sans-serif; text-align: center; padding-top: 50px;">
            <h1>❌ Authorization Failed</h1>
            <p>#{reason}</p>
            </body></html>
            """
            :gen_tcp.send(client_socket, response)
            :gen_tcp.close(client_socket)
            {:error, reason}
        end

      {:error, :timeout} ->
        {:error, "Timed out waiting for authorization (2 minutes)"}

      {:error, reason} ->
        {:error, "Failed to accept connection: #{inspect(reason)}"}
    end
  end

  defp read_http_request(socket, uri) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_request, :GET, {:abs_path, path}, _version}} ->
        read_http_request(socket, path)

      {:ok, :http_eoh} ->
        # End of headers, parse the URI we collected
        parse_callback_uri(uri)

      {:ok, {:http_header, _, _, _, _}} ->
        # Skip headers, continue reading
        read_http_request(socket, uri)

      {:ok, {:http_error, _}} ->
        read_http_request(socket, uri)

      {:error, reason} ->
        {:error, "Failed to read request: #{inspect(reason)}"}
    end
  end

  defp parse_callback_uri(nil), do: {:error, "No request received"}

  defp parse_callback_uri(path) do
    uri = URI.parse(path)
    query = URI.decode_query(uri.query || "")

    case query do
      %{"code" => code} ->
        IO.puts("✅ Received authorization code")
        {:ok, code}

      %{"error" => error} ->
        {:error, "OAuth error: #{error}"}

      _ ->
        {:error, "No authorization code in callback"}
    end
  end

  defp exchange_code_for_tokens(code, credentials) do
    IO.puts("\n🔄 Step 2: Exchanging authorization code for tokens...")

    # Debug: Show what we're sending
    IO.puts("🔍 Debug info:")
    IO.puts("  Client ID: #{String.slice(credentials.client_id, 0..20)}...")
    IO.puts("  Code length: #{String.length(code)} characters")
    IO.puts("  Code preview: #{String.slice(code, 0..20)}...")

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    body = URI.encode_query(%{
      "client_id" => credentials.client_id,
      "client_secret" => credentials.client_secret,
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => @redirect_uri
    })

    IO.puts("  Request body: #{body}")

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
        IO.puts("🔍 Full error response:")
        IO.puts("  Status: #{status}")
        IO.puts("  Body: #{body}")

        case Jason.decode(body) do
          {:ok, %{"error" => error, "error_description" => description}} ->
            {:error, "#{error}: #{description}"}
          {:ok, parsed} ->
            {:error, "Token exchange failed: #{inspect(parsed)}"}
          {:error, _} ->
            {:error, "Token exchange failed with status #{status}: #{body}"}
        end

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
