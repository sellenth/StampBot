defmodule DragNStamp.Timestamps.GeminiClient do
  @moduledoc """
  Invokes Gemini models for structured timestamp generation.

  Video and text workloads use separate configurable model tiers. Responses are
  validated against the application's timestamp contract before callers see them.
  """

  require Logger

  alias DragNStamp.Timestamps.{Prompts, TimestampSet}

  @api_base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_video_model "gemini-3.7-flash"
  @default_text_model "gemini-3.5-flash-lite"
  @default_video_thinking_level "medium"
  @default_text_thinking_level "low"
  @default_timeout 300_000
  @default_max_attempts 3
  @retryable_statuses [408, 409, 425, 429]

  defmodule Result do
    @moduledoc false

    @type t :: %__MODULE__{}

    @enforce_keys [:content, :timestamps, :model, :duration_ms, :attempts]
    defstruct [
      :content,
      :timestamps,
      :model,
      :model_version,
      :finish_reason,
      :thinking_level,
      :duration_ms,
      :attempts,
      usage: %{}
    ]
  end

  @type result :: %Result{}

  @spec video_model() :: binary()
  def video_model do
    configured_value(:video_model, "GEMINI_VIDEO_MODEL", @default_video_model)
  end

  @spec text_model() :: binary()
  def text_model do
    configured_value(:text_model, "GEMINI_TEXT_MODEL", @default_text_model)
  end

  @spec video_thinking_level() :: binary()
  def video_thinking_level do
    configured_value(
      :video_thinking_level,
      "GEMINI_VIDEO_THINKING_LEVEL",
      @default_video_thinking_level
    )
  end

  @spec text_thinking_level() :: binary()
  def text_thinking_level do
    configured_value(
      :text_thinking_level,
      "GEMINI_TEXT_THINKING_LEVEL",
      @default_text_thinking_level
    )
  end

  @spec timestamps_with_retry(binary(), binary(), binary() | nil, keyword()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def timestamps_with_retry(prompt, api_key, video_url, opts \\ []) do
    case timestamps_detailed_with_retry(prompt, api_key, video_url, opts) do
      {:ok, %Result{} = result} -> {:ok, result.content, result.model}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec timestamps_detailed_with_retry(binary(), binary(), binary() | nil, keyword()) ::
          {:ok, result()} | {:error, term()}
  def timestamps_detailed_with_retry(prompt, api_key, video_url, opts \\ []) do
    model = Keyword.get(opts, :model, video_model())
    thinking_level = Keyword.get(opts, :thinking_level, video_thinking_level())

    request_with_retry(
      fn attempt ->
        body =
          prompt
          |> video_body(video_url, opts)
          |> put_structured_generation_config(thinking_level, opts)

        request_once(model, body, api_key, :video, thinking_level, attempt, opts)
      end,
      opts
    )
  end

  @spec timestamps(binary(), binary(), binary() | nil, keyword()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def timestamps(prompt, api_key, video_url, opts \\ []) do
    timestamps_with_retry(prompt, api_key, video_url, Keyword.put(opts, :max_attempts, 1))
  end

  @spec text_only(binary(), binary(), keyword()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def text_only(prompt, api_key, opts \\ []) do
    case text_only_detailed(prompt, api_key, opts) do
      {:ok, %Result{} = result} -> {:ok, result.content, result.model}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec text_only_detailed(binary(), binary(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def text_only_detailed(prompt, api_key, opts \\ []) do
    model = Keyword.get(opts, :model, text_model())
    thinking_level = Keyword.get(opts, :thinking_level, text_thinking_level())

    request_with_retry(
      fn attempt ->
        body =
          prompt
          |> text_body()
          |> put_structured_generation_config(thinking_level, opts)

        request_once(model, body, api_key, :text, thinking_level, attempt, opts)
      end,
      opts
    )
  end

  defp request_with_retry(request_fun, opts, attempt \\ 1) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    case request_fun.(attempt) do
      {:ok, %Result{} = result} ->
        {:ok, %{result | attempts: attempt}}

      {:error, reason} = error ->
        if attempt < max_attempts and retryable?(reason) do
          delay = retry_delay(reason, attempt, opts)

          Logger.warning(
            "Gemini request attempt #{attempt} failed with #{error_summary(reason)}; retrying in #{delay}ms"
          )

          sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
          sleep_fun.(delay)
          request_with_retry(request_fun, opts, attempt + 1)
        else
          Logger.error(
            "Gemini request failed after #{attempt} attempt(s): #{error_summary(reason)}"
          )

          error
        end
    end
  end

  defp request_once(model, body, api_key, operation, thinking_level, attempt, opts) do
    api_url = "#{@api_base_url}/#{URI.encode(model)}:generateContent"

    headers = [
      {"Content-Type", "application/json"},
      {"x-goog-api-key", api_key}
    ]

    request = Finch.build(:post, api_url, headers, Jason.encode!(body))
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    request_fun = Keyword.get(opts, :request_fun, &default_request/2)
    started_at = System.monotonic_time()

    response = request_fun.(request, timeout)
    duration_native = System.monotonic_time() - started_at
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    case response do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_success(
          response_body,
          model,
          operation,
          thinking_level,
          attempt,
          duration_native,
          duration_ms,
          opts
        )

      {:ok, %Finch.Response{status: status, headers: response_headers, body: response_body}} ->
        reason = %{
          kind: :http,
          status: status,
          retry_after_ms: retry_after_ms(response_headers),
          body_preview: truncate(response_body)
        }

        emit_telemetry(
          duration_native,
          %{},
          model,
          nil,
          operation,
          thinking_level,
          attempt,
          reason
        )

        {:error, reason}

      {:error, reason} ->
        wrapped = %{kind: :transport, reason: inspect(reason)}

        emit_telemetry(
          duration_native,
          %{},
          model,
          nil,
          operation,
          thinking_level,
          attempt,
          wrapped
        )

        {:error, wrapped}
    end
  end

  defp parse_success(
         response_body,
         model,
         operation,
         thinking_level,
         attempt,
         duration_native,
         duration_ms,
         opts
       ) do
    with {:ok, payload} <- Jason.decode(response_body),
         {:ok, candidate, text} <- extract_candidate_text(payload),
         {:ok, content, timestamps} <-
           TimestampSet.decode(text, max_seconds: Keyword.get(opts, :max_seconds)) do
      usage = normalize_usage(Map.get(payload, "usageMetadata", %{}))
      model_version = Map.get(payload, "modelVersion")
      finish_reason = Map.get(candidate, "finishReason")

      result = %Result{
        content: content,
        timestamps: timestamps,
        model: model,
        model_version: model_version,
        finish_reason: finish_reason,
        thinking_level: thinking_level,
        duration_ms: duration_ms,
        attempts: attempt,
        usage: usage
      }

      emit_telemetry(
        duration_native,
        usage,
        model,
        model_version,
        operation,
        thinking_level,
        attempt,
        :ok
      )

      Logger.info(
        "Gemini #{operation} request succeeded model=#{model_version || model} attempt=#{attempt} duration_ms=#{duration_ms} timestamps=#{length(timestamps)} total_tokens=#{usage.total_tokens}"
      )

      {:ok, result}
    else
      {:error, %Jason.DecodeError{} = error} ->
        reason = %{kind: :invalid_json_response, position: error.position}

        emit_telemetry(
          duration_native,
          %{},
          model,
          nil,
          operation,
          thinking_level,
          attempt,
          reason
        )

        {:error, reason}

      {:error, reason} ->
        wrapped = %{kind: :invalid_model_output, reason: reason}

        emit_telemetry(
          duration_native,
          %{},
          model,
          nil,
          operation,
          thinking_level,
          attempt,
          wrapped
        )

        {:error, wrapped}
    end
  end

  defp extract_candidate_text(%{"candidates" => [candidate | _]}) when is_map(candidate) do
    parts = get_in(candidate, ["content", "parts"]) || []

    text =
      parts
      |> Enum.reject(&(Map.get(&1, "thought") == true))
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.filter(&is_binary/1)
      |> Enum.join()

    if String.trim(text) == "" do
      {:error,
       {:missing_candidate_text, Map.get(candidate, "finishReason"),
        Map.get(candidate, "safetyRatings", [])}}
    else
      {:ok, candidate, text}
    end
  end

  defp extract_candidate_text(%{"promptFeedback" => feedback}),
    do: {:error, {:prompt_blocked, feedback}}

  defp extract_candidate_text(_payload), do: {:error, :missing_candidates}

  defp video_body(prompt, video_url, opts) do
    parts =
      []
      |> maybe_with_video_part(video_url)
      |> Kernel.++([%{text: prompt}])

    %{contents: [%{role: "user", parts: parts}]}
    |> put_system_instruction(
      Keyword.get(opts, :system_instruction, Prompts.system_instruction())
    )
  end

  defp text_body(prompt) do
    %{contents: [%{role: "user", parts: [%{text: prompt}]}]}
    |> put_system_instruction(Prompts.system_instruction())
  end

  defp put_system_instruction(body, nil), do: body

  defp put_system_instruction(body, instruction) when is_binary(instruction) do
    Map.put(body, "systemInstruction", %{parts: [%{text: instruction}]})
  end

  defp put_structured_generation_config(body, thinking_level, opts) do
    caller_config = Keyword.get(opts, :generation_config, %{})

    config =
      caller_config
      |> Map.put("responseMimeType", "application/json")
      |> Map.put("responseSchema", TimestampSet.json_schema())
      |> maybe_put_thinking_level(thinking_level)

    Map.put(body, "generationConfig", config)
  end

  defp maybe_put_thinking_level(config, nil), do: config

  defp maybe_put_thinking_level(config, thinking_level) when is_binary(thinking_level) do
    Map.put(config, "thinkingConfig", %{"thinkingLevel" => thinking_level})
  end

  defp maybe_with_video_part(parts, nil), do: parts

  defp maybe_with_video_part(parts, url) do
    parts ++ [%{file_data: %{file_uri: url, mimeType: "video/mp4"}}]
  end

  defp configured_value(config_key, env_key, default) do
    config = Application.get_env(:drag_n_stamp, :gemini, [])
    System.get_env(env_key) || Keyword.get(config, config_key, default)
  end

  defp default_request(request, timeout) do
    Finch.request(request, DragNStamp.Finch, receive_timeout: timeout)
  end

  defp retryable?(%{kind: :transport}), do: true
  defp retryable?(%{kind: :invalid_model_output}), do: true
  defp retryable?(%{kind: :invalid_json_response}), do: true
  defp retryable?(%{kind: :http, status: status}) when status in @retryable_statuses, do: true
  defp retryable?(%{kind: :http, status: status}) when status >= 500, do: true
  defp retryable?(_reason), do: false

  defp retry_delay(%{retry_after_ms: retry_after_ms}, _attempt, _opts)
       when is_integer(retry_after_ms) and retry_after_ms > 0,
       do: retry_after_ms

  defp retry_delay(_reason, attempt, opts) do
    delays = Keyword.get(opts, :retry_delays, [1_000, 3_000])
    base_delay = Enum.at(delays, attempt - 1, List.last(delays) || 1_000)
    jitter = Keyword.get(opts, :retry_jitter, 250)

    if jitter > 0, do: base_delay + :rand.uniform(jitter) - 1, else: base_delay
  end

  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(name) == "retry-after", do: value
    end)
    |> case do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1_000
          _ -> nil
        end
    end
  end

  defp normalize_usage(usage) do
    %{
      prompt_tokens: Map.get(usage, "promptTokenCount", 0),
      output_tokens: Map.get(usage, "candidatesTokenCount", 0),
      thinking_tokens: Map.get(usage, "thoughtsTokenCount", 0),
      total_tokens: Map.get(usage, "totalTokenCount", 0),
      cached_tokens: Map.get(usage, "cachedContentTokenCount", 0)
    }
  end

  defp emit_telemetry(
         duration,
         usage,
         model,
         model_version,
         operation,
         thinking_level,
         attempt,
         status
       ) do
    measurements = %{
      duration: duration,
      prompt_tokens: Map.get(usage, :prompt_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      thinking_tokens: Map.get(usage, :thinking_tokens, 0),
      total_tokens: Map.get(usage, :total_tokens, 0)
    }

    metadata = %{
      model: model,
      model_version: model_version,
      operation: operation,
      thinking_level: thinking_level,
      attempt: attempt,
      status: telemetry_status(status)
    }

    :telemetry.execute([:drag_n_stamp, :gemini, :request], measurements, metadata)
  end

  defp telemetry_status(:ok), do: :ok
  defp telemetry_status(%{kind: kind}), do: kind
  defp telemetry_status(_status), do: :error

  defp error_summary(%{kind: :http, status: status}), do: "HTTP #{status}"
  defp error_summary(%{kind: kind}), do: Atom.to_string(kind)
  defp error_summary(reason), do: inspect(reason)

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp truncate(value), do: inspect(value) |> String.slice(0, 500)
end
