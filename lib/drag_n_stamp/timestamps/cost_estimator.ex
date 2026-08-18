defmodule DragNStamp.Timestamps.CostEstimator do
  @moduledoc """
  Estimates Gemini request cost from response usage metadata.

  Rates are configurable and expressed in USD per one million tokens. Estimates
  intentionally use successful response usage only; requests that fail without
  usage metadata cannot be included.
  """

  alias DragNStamp.Timestamps.GeminiClient.Result

  @million Decimal.new(1_000_000)

  @spec estimate_usd(Result.t()) :: Decimal.t() | nil
  def estimate_usd(%Result{model: model, usage: usage}) when is_binary(model) and is_map(usage) do
    with {:ok, rates} <- rates_for(model) do
      prompt_tokens = Map.get(usage, :prompt_tokens, 0)
      cached_tokens = min(Map.get(usage, :cached_tokens, 0), prompt_tokens)
      regular_input_tokens = prompt_tokens - cached_tokens
      output_tokens = Map.get(usage, :output_tokens, 0) + Map.get(usage, :thinking_tokens, 0)

      input_rate = Map.fetch!(rates, :input_per_million)
      cached_input_rate = Map.get(rates, :cached_input_per_million, input_rate)

      input_cost = token_cost(regular_input_tokens, input_rate)
      cached_input_cost = token_cost(cached_tokens, cached_input_rate)
      output_cost = token_cost(output_tokens, Map.fetch!(rates, :output_per_million))

      input_cost
      |> Decimal.add(cached_input_cost)
      |> Decimal.add(output_cost)
    else
      :error -> nil
    end
  end

  def estimate_usd(_result), do: nil

  @spec add(Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  def add(nil, nil), do: nil
  def add(nil, %Decimal{} = cost), do: cost
  def add(%Decimal{} = cost, nil), do: cost
  def add(%Decimal{} = left, %Decimal{} = right), do: Decimal.add(left, right)

  @spec serialize(Decimal.t() | nil) :: binary() | nil
  def serialize(nil), do: nil
  def serialize(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  @spec parse(term()) :: Decimal.t() | nil
  def parse(%Decimal{} = value), do: value

  def parse(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> decimal
      _ -> nil
    end
  end

  def parse(value) when is_integer(value), do: Decimal.new(value)
  def parse(value) when is_float(value), do: Decimal.from_float(value)
  def parse(_value), do: nil

  defp rates_for(model) do
    rates = Application.get_env(:drag_n_stamp, :gemini_cost_rates, %{})

    rates
    |> Enum.sort_by(fn {model_prefix, _rates} -> String.length(model_prefix) end, :desc)
    |> Enum.find_value(:error, fn {model_prefix, model_rates} ->
      if String.starts_with?(model, model_prefix), do: {:ok, model_rates}
    end)
  end

  defp token_cost(tokens, rate) when is_integer(tokens) and tokens >= 0 do
    tokens
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(rate))
    |> Decimal.div(@million)
  end
end
