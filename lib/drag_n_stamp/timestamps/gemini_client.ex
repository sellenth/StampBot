defmodule DragNStamp.Timestamps.GeminiClient do
  @moduledoc """
  Invokes Gemini models for structured timestamp generation.

  Video and text workloads use separate configurable model tiers. Responses are
  validated against the application's timestamp contract before callers see them.
  """

  require Logger

  alias DragNStamp.{ProcessingAttempts, WorkBudget}
  alias DragNStamp.Timestamps.{CostEstimator, Prompts, TimestampSet}

  @api_base_url "https://generativelanguage.googleapis.com/v1beta/models"
  @default_video_model "gemini-3.7-flash"
  @default_text_model "gemini-3.5-flash-lite"
  @default_video_thinking_level "medium"
  @default_text_thinking_level "low"
  @default_timeout 300_000
  @default_max_attempts 3
  @retryable_statuses [408, 409, 425, 429]
  @schema_version "timestamps-v1"
  @max_output_tokens 8_192

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
      :request_cost_usd,
      unknown_cost_attempts: 0,
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

  defp request_with_retry(
         request_fun,
         opts,
         attempt \\ 1,
         previous_cost \\ nil,
         unknown_costs \\ 0
       ) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    case request_fun.(attempt) do
      {:ok, %Result{} = result} ->
        {:ok,
         %{
           result
           | attempts: attempt,
             request_cost_usd:
               CostEstimator.add(previous_cost, CostEstimator.estimate_usd(result)),
             unknown_cost_attempts: unknown_costs + result.unknown_cost_attempts
         }}

      {:error, reason} ->
        total_cost =
          CostEstimator.add(previous_cost, CostEstimator.parse(reason[:request_cost_usd]))

        total_unknown = unknown_costs + Map.get(reason, :unknown_cost_attempts, 0)

        if attempt < max_attempts and retryable?(reason) do
          delay = retry_delay(reason, attempt, opts)

          Logger.warning(
            "Gemini request attempt #{attempt} failed with #{error_summary(reason)}; retrying in #{delay}ms"
          )

          sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
          sleep_fun.(delay)
          request_with_retry(request_fun, opts, attempt + 1, total_cost, total_unknown)
        else
          Logger.error(
            "Gemini request failed after #{attempt} attempt(s): #{error_summary(reason)}"
          )

          {:error,
           Map.merge(reason, %{
             request_cost_usd: CostEstimator.serialize(total_cost),
             unknown_cost_attempts: total_unknown
           })}
        end
    end
  end

  defp request_once(model, body, api_key, operation, thinking_level, attempt, opts) do
    ctx = ProcessingAttempts.context()

    attrs = %{
      kind: :request,
      stage: ctx[:stage] || if(operation == :video, do: "video", else: "distillation"),
      provider: "gemini",
      operation: operation,
      request_attempt: attempt,
      model: model,
      thinking_level: thinking_level,
      prompt_version: Keyword.get(opts, :prompt_version, ctx[:prompt_version] || "unspecified"),
      schema_version: @schema_version,
      input_bytes: byte_size(Jason.encode!(body))
    }

    ProcessingAttempts.around(attrs, fn handle ->
      context = ProcessingAttempts.context()

      with :ok <- WorkBudget.check_request(context, body),
           :ok <- WorkBudget.before_request(context) do
        ProcessingAttempts.annotate(handle, %{dispatched: true})
        dispatch_request(model, body, api_key, operation, thinking_level, attempt, opts, handle)
      else
        {:error, reason} ->
          ProcessingAttempts.annotate(handle, %{
            cost_status: :not_dispatched,
            estimated_cost_usd: Decimal.new(0)
          })

          {:error, %{kind: reason, unknown_cost_attempts: 0, request_cost_usd: "0"}}
      end
    end)
  end

  defp dispatch_request(model, body, api_key, operation, thinking_level, attempt, opts, handle) do
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

    {result, usage, model_version} =
      case response do
        {:ok, %Finch.Response{status: status, headers: response_headers, body: response_body}} ->
          decoded = Jason.decode(response_body)

          payload =
            case decoded do
              {:ok, value} when is_map(value) -> value
              _ -> %{}
            end

          usage = normalize_usage(Map.get(payload, "usageMetadata", %{}))
          model_version = safe_identifier(Map.get(payload, "modelVersion"), 128)

          # Usage is committed before parsing or validating the candidate output.
          # A rejected response may still be billable and must survive a later crash.
          cost =
            ProcessingAttempts.response(
              handle,
              %{
                model: model,
                model_version: model_version,
                http_status: status,
                provider_request_id: provider_request_id(payload, response_headers),
                finish_reason: finish_reason(payload)
              },
              usage
            )

          result =
            if status == 200 do
              case decoded do
                {:ok, value} when is_map(value) ->
                  parse_success(
                    value,
                    model,
                    model_version,
                    thinking_level,
                    attempt,
                    duration_ms,
                    usage,
                    cost,
                    opts
                  )

                _ ->
                  {:error, %{kind: :invalid_json_response}}
              end
            else
              {:error,
               %{kind: :http, status: status, retry_after_ms: retry_after_ms(response_headers)}}
            end

          result = with_cost_metadata(result, cost)
          {result, usage, model_version}

        {:error, reason} ->
          wrapped = %{
            kind: :transport,
            reason: transport_reason(reason),
            unknown_cost_attempts: 1
          }

          {{:error, wrapped}, %{}, nil}
      end

    status =
      case result do
        {:ok, _} -> :ok
        {:error, reason} -> reason
      end

    emit_telemetry(
      duration_native,
      usage,
      model,
      model_version,
      operation,
      thinking_level,
      attempt,
      status
    )

    result
  end

  defp parse_success(
         payload,
         model,
         model_version,
         thinking_level,
         attempt,
         duration_ms,
         usage,
         cost,
         opts
       ) do
    with {:ok, candidate, text} <- extract_candidate_text(payload),
         {:ok, content, timestamps} <-
           TimestampSet.decode(text, max_seconds: Keyword.get(opts, :max_seconds)),
         :ok <- reject_unwatched(timestamps) do
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
        usage: usage,
        request_cost_usd: cost,
        unknown_cost_attempts: if(is_nil(cost), do: 1, else: 0)
      }

      Logger.info(
        "Gemini request succeeded model=#{model_version || model} attempt=#{attempt} duration_ms=#{duration_ms} timestamps=#{length(timestamps)} total_tokens=#{Map.get(usage, :total_tokens, "unknown")}"
      )

      {:ok, result}
    else
      {:error, reason} ->
        {:error, %{kind: :invalid_model_output, reason: reason}}
    end
  end

  defp extract_candidate_text(%{"candidates" => [candidate | _]}) when is_map(candidate) do
    parts =
      case Map.get(candidate, "content") do
        %{"parts" => parts} when is_list(parts) -> Enum.filter(parts, &is_map/1)
        _ -> []
      end

    text =
      parts
      |> Enum.reject(&(Map.get(&1, "thought") == true))
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.filter(&is_binary/1)
      |> Enum.join()

    cond do
      Map.get(candidate, "finishReason") != "STOP" -> {:error, :incomplete_output}
      String.trim(text) == "" -> {:error, :missing_candidate_text}
      true -> {:ok, candidate, text}
    end
  end

  defp extract_candidate_text(%{"promptFeedback" => _feedback}), do: {:error, :prompt_blocked}

  defp extract_candidate_text(_payload), do: {:error, :missing_candidates}

  defp reject_unwatched(timestamps) do
    if Enum.any?(timestamps, &(String.upcase(String.trim(&1.title)) == "UNWATCHED")),
      do: {:error, :unwatched},
      else: :ok
  end

  defp with_cost_metadata({:ok, _} = result, _cost), do: result

  defp with_cost_metadata({:error, reason}, cost),
    do:
      {:error,
       Map.merge(reason, %{
         request_cost_usd: CostEstimator.serialize(cost),
         unknown_cost_attempts: if(is_nil(cost), do: 1, else: 0)
       })}

  defp provider_request_id(payload, headers) do
    id =
      Map.get(payload, "responseId") ||
        Enum.find_value(headers, fn {key, value} ->
          if String.downcase(key) in ["x-request-id", "x-goog-request-id"], do: value
        end)

    safe_identifier(id, 255)
  end

  defp finish_reason(%{"candidates" => [candidate | _]}) when is_map(candidate),
    do: safe_identifier(candidate["finishReason"], 64)

  defp finish_reason(_), do: nil

  defp safe_identifier(value, limit) when is_binary(value),
    do: value |> String.replace(~r/[[:cntrl:]]/, "") |> String.slice(0, limit)

  defp safe_identifier(_value, _limit), do: nil

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(reason) when is_atom(reason), do: reason
  defp transport_reason(_reason), do: :transport_error

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
      |> Map.put("maxOutputTokens", output_token_limit(caller_config))
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

  defp retryable?(%{kind: :invalid_model_output, reason: reason})
       when reason in [:unwatched, :incomplete_output, :prompt_blocked],
       do: false

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

  defp normalize_usage(usage) when is_map(usage) do
    [
      {:prompt_tokens, "promptTokenCount"},
      {:output_tokens, "candidatesTokenCount"},
      {:thinking_tokens, "thoughtsTokenCount"},
      {:total_tokens, "totalTokenCount"},
      {:cached_tokens, "cachedContentTokenCount"}
    ]
    |> Enum.reduce(%{}, fn {field, source}, acc ->
      case usage[source] do
        count when is_integer(count) and count >= 0 -> Map.put(acc, field, count)
        _ -> acc
      end
    end)
  end

  defp normalize_usage(_usage), do: %{}

  defp output_token_limit(config) do
    case config["maxOutputTokens"] do
      value when is_integer(value) and value > 0 -> min(value, @max_output_tokens)
      _ -> @max_output_tokens
    end
  end

  defp emit_telemetry(
         duration,
         usage,
         _model,
         _model_version,
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
      model: if(operation == :video, do: "video-tier", else: "text-tier"),
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
end
