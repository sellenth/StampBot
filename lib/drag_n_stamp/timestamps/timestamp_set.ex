defmodule DragNStamp.Timestamps.TimestampSet do
  @moduledoc """
  Decodes, validates, and renders structured timestamp responses.

  Gemini returns seconds as integers so formatting stays deterministic and
  YouTube-specific rendering remains application code rather than model output.
  """

  @max_timestamps 24
  @max_title_length 160

  @type timestamp :: %{seconds: non_neg_integer(), title: String.t()}

  @spec json_schema() :: map()
  def json_schema do
    %{
      "type" => "object",
      "description" => "An ordered set of YouTube chapter timestamps.",
      "properties" => %{
        "timestamps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_timestamps,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "seconds" => %{
                "type" => "integer",
                "minimum" => 0,
                "description" => "Whole seconds from the beginning of the video."
              },
              "title" => %{
                "type" => "string",
                "description" =>
                  "A specific, engaging chapter title of 8 to 12 words with no timecode or bullet."
              }
            },
            "required" => ["seconds", "title"]
          }
        }
      },
      "required" => ["timestamps"]
    }
  end

  @spec decode(binary(), keyword()) :: {:ok, binary(), [timestamp()]} | {:error, term()}
  def decode(text, opts \\ [])

  def decode(text, opts) when is_binary(text) do
    with {:ok, %{"timestamps" => raw_timestamps}} <- Jason.decode(text),
         {:ok, timestamps} <- validate(raw_timestamps, opts) do
      {:ok, render(timestamps), timestamps}
    else
      {:ok, _other} -> {:error, :invalid_timestamp_envelope}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, error.position}}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_text, _opts), do: {:error, :missing_structured_output}

  @spec validate(term(), keyword()) :: {:ok, [timestamp()]} | {:error, term()}
  def validate(raw_timestamps, opts \\ [])

  def validate(raw_timestamps, opts) when is_list(raw_timestamps) do
    max_seconds = Keyword.get(opts, :max_seconds)

    with :ok <- validate_count(raw_timestamps),
         {:ok, timestamps} <- normalize_all(raw_timestamps),
         :ok <- validate_order(timestamps),
         :ok <- validate_bounds(timestamps, max_seconds) do
      {:ok, timestamps}
    end
  end

  def validate(_raw_timestamps, _opts), do: {:error, :timestamps_must_be_a_list}

  @spec render([timestamp()]) :: binary()
  def render(timestamps) do
    Enum.map_join(timestamps, "\n", fn %{seconds: seconds, title: title} ->
      "#{format_seconds(seconds)} #{title}"
    end)
  end

  @spec format_seconds(non_neg_integer()) :: binary()
  def format_seconds(total_seconds) when is_integer(total_seconds) and total_seconds >= 0 do
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      "#{hours}:#{pad(minutes)}:#{pad(seconds)}"
    else
      "#{minutes}:#{pad(seconds)}"
    end
  end

  defp validate_count([]), do: {:error, :timestamps_empty}

  defp validate_count(timestamps) when length(timestamps) > @max_timestamps,
    do: {:error, {:too_many_timestamps, length(timestamps)}}

  defp validate_count(_timestamps), do: :ok

  defp normalize_all(raw_timestamps) do
    raw_timestamps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {timestamp, index}, {:ok, acc} ->
      case normalize(timestamp) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_timestamp, index, reason}}}
      end
    end)
    |> case do
      {:ok, timestamps} -> {:ok, Enum.reverse(timestamps)}
      error -> error
    end
  end

  defp normalize(%{"seconds" => seconds, "title" => title})
       when is_integer(seconds) and seconds >= 0 and is_binary(title) do
    normalized_title = title |> String.replace(~r/\s+/, " ") |> String.trim()

    cond do
      normalized_title == "" -> {:error, :title_empty}
      String.length(normalized_title) > @max_title_length -> {:error, :title_too_long}
      String.contains?(normalized_title, "\n") -> {:error, :title_contains_newline}
      true -> {:ok, %{seconds: seconds, title: normalized_title}}
    end
  end

  defp normalize(_timestamp), do: {:error, :invalid_fields}

  defp validate_order(timestamps) do
    timestamps
    |> Enum.map(& &1.seconds)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [first, second] -> second <= first end)
    |> case do
      nil -> :ok
      [first, second] -> {:error, {:timestamps_not_strictly_increasing, first, second}}
    end
  end

  defp validate_bounds(_timestamps, nil), do: :ok

  defp validate_bounds(timestamps, max_seconds)
       when is_integer(max_seconds) and max_seconds > 0 do
    case Enum.find(timestamps, &(&1.seconds > max_seconds)) do
      nil -> :ok
      timestamp -> {:error, {:timestamp_out_of_bounds, timestamp.seconds, max_seconds}}
    end
  end

  defp validate_bounds(_timestamps, _max_seconds), do: {:error, :invalid_max_seconds}

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: Integer.to_string(value)
end
