defmodule DragNStamp.Timestamps.GeminiClientTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.GeminiClient

  test "uses the configured video model, API key header, thinking level, and schema" do
    parent = self()

    request_fun = fn request, timeout ->
      send(parent, {:request, request, timeout})
      successful_response("gemini-3.7-flash-2026-08", 100)
    end

    assert {:ok, result} =
             GeminiClient.timestamps_detailed_with_retry(
               "Create timestamps",
               "secret-key",
               "https://www.youtube.com/watch?v=abc",
               request_fun: request_fun,
               max_attempts: 1,
               max_seconds: 120
             )

    assert result.model == "gemini-3.7-flash"
    assert result.model_version == "gemini-3.7-flash-2026-08"
    assert result.content == "0:00 Opening moment introduces the main idea"
    assert result.usage.total_tokens == 15

    assert_receive {:request, request, 300_000}
    assert request.path == "/v1beta/models/gemini-3.7-flash:generateContent"
    assert request.query == nil
    assert {"x-goog-api-key", "secret-key"} in request.headers

    body = Jason.decode!(request.body)
    assert get_in(body, ["generationConfig", "thinkingConfig", "thinkingLevel"]) == "medium"
    assert get_in(body, ["generationConfig", "responseMimeType"]) == "application/json"
    assert get_in(body, ["generationConfig", "responseSchema", "type"]) == "object"
    assert get_in(body, ["contents", Access.at(0), "parts", Access.at(0), "file_data"])
  end

  test "does not retry permanent client errors" do
    counter = :counters.new(1, [])

    request_fun = fn _request, _timeout ->
      :counters.add(counter, 1, 1)
      {:ok, %Finch.Response{status: 401, headers: [], body: ~s({"error":"bad key"})}}
    end

    assert {:error, %{kind: :http, status: 401}} =
             GeminiClient.text_only("Prompt", "bad-key",
               request_fun: request_fun,
               max_attempts: 3,
               retry_jitter: 0
             )

    assert :counters.get(counter, 1) == 1
  end

  test "honors retry-after for rate limits and reports the final attempt count" do
    counter = :counters.new(1, [])
    parent = self()

    request_fun = fn _request, _timeout ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        {:ok,
         %Finch.Response{
           status: 429,
           headers: [{"retry-after", "2"}],
           body: ~s({"error":"slow down"})
         }}
      else
        successful_response("gemini-3.5-flash-lite", 100)
      end
    end

    sleep_fun = fn delay -> send(parent, {:slept, delay}) end

    assert {:ok, result} =
             GeminiClient.text_only_detailed("Prompt", "key",
               request_fun: request_fun,
               sleep_fun: sleep_fun,
               max_attempts: 2,
               retry_jitter: 0
             )

    assert result.attempts == 2
    assert_receive {:slept, 2_000}
  end

  defp successful_response(model_version, seconds) do
    structured =
      Jason.encode!(%{
        "timestamps" => [
          %{"seconds" => seconds - 100, "title" => "Opening moment introduces the main idea"}
        ]
      })

    body =
      Jason.encode!(%{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => structured}]},
            "finishReason" => "STOP"
          }
        ],
        "modelVersion" => model_version,
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      })

    {:ok, %Finch.Response{status: 200, headers: [], body: body}}
  end
end
