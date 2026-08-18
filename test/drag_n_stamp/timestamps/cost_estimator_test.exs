defmodule DragNStamp.Timestamps.CostEstimatorTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.{CostEstimator, GeminiClient}

  test "estimates prompt, output, and thinking-token cost" do
    result = %GeminiClient.Result{
      content: "0:00 Intro",
      timestamps: [%{seconds: 0, title: "Intro"}],
      model: "gemini-3.7-flash",
      duration_ms: 1,
      attempts: 1,
      usage: %{
        prompt_tokens: 1_000_000,
        output_tokens: 100_000,
        thinking_tokens: 100_000
      }
    }

    assert Decimal.equal?(CostEstimator.estimate_usd(result), Decimal.new("1.50"))
  end

  test "adds and serializes stage costs while preserving unknown values" do
    generation = Decimal.new("0.01234567")
    distillation = Decimal.new("0.00012345")

    assert CostEstimator.add(nil, nil) == nil

    assert generation
           |> CostEstimator.add(distillation)
           |> CostEstimator.serialize() == "0.01246912"

    assert CostEstimator.parse("0.01246912") == Decimal.new("0.01246912")
  end

  test "prices cached input tokens at the configured discounted rate" do
    result = %GeminiClient.Result{
      content: "0:00 Intro",
      timestamps: [],
      model: "gemini-3.7-flash",
      duration_ms: 1,
      attempts: 1,
      usage: %{
        prompt_tokens: 1_000_000,
        cached_tokens: 800_000,
        output_tokens: 0,
        thinking_tokens: 0
      }
    }

    assert Decimal.equal?(CostEstimator.estimate_usd(result), Decimal.new("0.21"))
  end

  test "returns nil when a configured rate is unavailable" do
    result = %GeminiClient.Result{
      content: "0:00 Intro",
      timestamps: [],
      model: "custom-model",
      duration_ms: 1,
      attempts: 1,
      usage: %{prompt_tokens: 10, output_tokens: 10, thinking_tokens: 0}
    }

    assert CostEstimator.estimate_usd(result) == nil
  end
end
