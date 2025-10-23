defmodule DragNStamp.Timestamps.Parser do
  @moduledoc """
  Helpers for extracting and normalizing timestamp content returned by Gemini.
  """

  require Logger

  @timestamp_regex ~r/^\s*\d+:\d+/

  @spec extract_timestamps_only(binary() | nil) :: binary() | {:error, term()}
  def extract_timestamps_only(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line -> String.match?(line, @timestamp_regex) end)
    |> Enum.join("\n")
  end

  def extract_timestamps_only(nil) do
    Logger.error("Parser.extract_timestamps_only received nil - Gemini API returned no text")
    {:error, :nil_response}
  end

  def extract_timestamps_only(other) do
    Logger.error("Parser.extract_timestamps_only received unexpected type: #{inspect(other)}")
    {:error, :unexpected_type}
  end
end

