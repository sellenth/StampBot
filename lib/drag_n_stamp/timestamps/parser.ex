defmodule DragNStamp.Timestamps.Parser do
  @moduledoc """
  Helpers for extracting and normalizing timestamp content returned by Gemini.
  """

  require Logger

  # Match timestamps with colons (0:00) or spaces (0 00)
  @timestamp_regex ~r/^\s*\d+[:\s]\d+/

  @spec extract_timestamps_only(binary() | nil) :: binary() | {:error, term()}
  def extract_timestamps_only(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(fn line -> String.match?(line, @timestamp_regex) end)
    |> Enum.map(&normalize_timestamp/1)
    |> Enum.join("\n")
  end

  # Convert "0 00 Description" to "0:00 Description"
  defp normalize_timestamp(line) do
    Regex.replace(~r/^(\s*)(\d+)\s(\d+)/, line, "\\1\\2:\\3")
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

