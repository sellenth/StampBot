defmodule DragNStamp.SEO.ChapterParser do
  @moduledoc """
  Converts timestamp text blobs into structured chapter data for SEO pages.
  """

  alias DragNStamp.Timestamp

  @stamp_regex ~r/^(?<time>\d{1,2}:\d{2}(?::\d{2})?)\s*(?:[-–—]\s*)?(?<title>.+)$/u

  @doc """
  Parse chapter data from a timestamp struct. Prefers distilled content when available.
  """
  @spec from_timestamp(Timestamp.t()) :: [map()]
  def from_timestamp(%Timestamp{} = timestamp) do
    source = timestamp.distilled_content || timestamp.content || ""
    from_text(source)
  end

  @doc """
  Parse chapter data from a raw multiline string.
  """
  @spec from_text(String.t()) :: [map()]
  def from_text(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&reject_line?/1)
    |> Enum.reduce([], fn line, acc ->
      case parse_line(line) do
        {:ok, chapter} -> [chapter | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end

  def from_text(_), do: []

  defp reject_line?(""), do: true

  defp reject_line?(line) do
    String.match?(String.downcase(line), ~r/^timestamps by stampbot/) or
      String.match?(String.downcase(line), ~r/^(?:generated\s+)?by stampbot/)
  end

  defp parse_line(line) do
    with %{"time" => timecode, "title" => title} <- Regex.named_captures(@stamp_regex, line),
         {:ok, starts_at} <- parse_timecode(timecode) do
      {:ok,
       %{
         timecode: timecode,
         title: String.trim(title),
         starts_at: starts_at,
         raw: line
       }}
    else
      _ -> :error
    end
  end

  defp parse_timecode(timecode) do
    parts =
      timecode
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    seconds =
      case parts do
        [minutes, seconds] -> minutes * 60 + seconds
        [hours, minutes, seconds] -> hours * 3600 + minutes * 60 + seconds
        _ -> nil
      end

    if is_integer(seconds) do
      {:ok, seconds}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end
end
