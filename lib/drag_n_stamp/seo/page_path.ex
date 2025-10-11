defmodule DragNStamp.SEO.PagePath do
  @moduledoc """
  Helpers for computing the static submission page slug and paths for timestamps.
  """

  alias DragNStamp.Timestamp

  @spec slug(Timestamp.t()) :: String.t()
  def slug(%Timestamp{} = timestamp) do
    source =
      cond do
        present?(timestamp.video_title) -> timestamp.video_title
        present?(timestamp.channel_name) -> timestamp.channel_name
        present?(timestamp.distilled_content) -> timestamp.distilled_content
        present?(timestamp.content) -> timestamp.content
        true -> "timestamp"
      end

    source
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "timestamp"
      slug -> String.slice(slug, 0, 60)
    end
  end

  @spec filename(Timestamp.t()) :: String.t()
  def filename(%Timestamp{id: id} = timestamp) when not is_nil(id) do
    "#{id}-#{slug(timestamp)}.html"
  end

  def filename(%Timestamp{} = timestamp) do
    "tmp-#{slug(timestamp)}.html"
  end

  @spec page_path(Timestamp.t()) :: String.t()
  def page_path(%Timestamp{} = timestamp) do
    "/submissions/" <> filename(timestamp)
  end

  @spec page_url(Timestamp.t(), String.t()) :: String.t()
  def page_url(%Timestamp{} = timestamp, base_url) do
    base = base_url |> to_string() |> String.trim_trailing("/")
    base <> page_path(timestamp)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
