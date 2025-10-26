defmodule DragNStamp.Timestamps.GeminiClient do
  @moduledoc """
  Provides helpers for invoking Gemini models for timestamp generation and text-only summarization.
  """

  require Logger

  alias DragNStamp.Timestamps.Parser

  @base_url "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
  @text_only_url "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent"

  @spec timestamps_with_retry(binary(), binary(), binary() | nil, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def timestamps_with_retry(prompt, api_key, video_url, opts \\ []) do
    do_timestamps_with_retry(prompt, api_key, video_url, opts, 1)
  end

  defp do_timestamps_with_retry(prompt, api_key, video_url, opts, attempt) do
    case timestamps(prompt, api_key, video_url, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when attempt < 3 ->
        delay = if attempt == 1, do: 5_000, else: 60_000

        Logger.warning(
          "Gemini API attempt #{attempt} failed: #{inspect(reason)}. Retrying in #{delay}ms..."
        )

        Process.sleep(delay)
        do_timestamps_with_retry(prompt, api_key, video_url, opts, attempt + 1)

      {:error, reason} ->
        Logger.error("Gemini API failed after #{attempt} attempts: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec timestamps(binary(), binary(), binary() | nil, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def timestamps(prompt, api_key, video_url, opts \\ []) do
    api_url = "#{@base_url}?key=#{api_key}"
    headers = [{"Content-Type", "application/json"}]

    parts =
      [%{text: prompt}]
      |> maybe_with_video_part(video_url)

    body =
      %{contents: [%{parts: parts}]}
      |> maybe_put_generation_config(opts)

    request = Finch.build(:post, api_url, headers, Jason.encode!(body))

    with {:ok, %Finch.Response{status: 200, body: response_body}} <-
           Finch.request(request, DragNStamp.Finch, receive_timeout: 300_000),
         {:ok, %{"candidates" => candidates}} <- Jason.decode(response_body),
         text <- get_in(candidates, [Access.at(0), "content", "parts", Access.at(0), "text"]),
         :ok <- log_raw_response(text),
         {:ok, cleaned} <- parse_timestamps(text) do
      {:ok, cleaned}
    else
      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP request failed with status: #{status}"}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP request failed with status: #{status} and body: #{body}"}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, "Failed to parse response: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec text_only(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def text_only(prompt, api_key) do
    api_url = "#{@text_only_url}?key=#{api_key}"
    headers = [{"Content-Type", "application/json"}]
    body = %{contents: [%{parts: [%{text: prompt}]}]}

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

  defp maybe_with_video_part(parts, nil), do: parts
  defp maybe_with_video_part(parts, url), do: parts ++ [build_video_part(url)]

  defp maybe_put_generation_config(body, opts) do
    case Keyword.get(opts, :generation_config) do
      nil -> body
      config when is_map(config) -> Map.put(body, "generationConfig", config)
    end
  end

  defp build_video_part(url) do
    %{file_data: %{file_uri: url}}
  end

  defp parse_timestamps(text) do
    case Parser.extract_timestamps_only(text) do
      {:error, reason} ->
        Logger.error("Failed to extract timestamps: #{inspect(reason)}")
        {:error, "No valid timestamps in response"}

      cleaned ->
        Logger.info("Gemini API cleaned timestamps: #{inspect(cleaned)}")
        {:ok, cleaned}
    end
  end

  defp log_raw_response(text) do
    Logger.info("Gemini API raw response: #{inspect(text)}")
    :ok
  end
end
