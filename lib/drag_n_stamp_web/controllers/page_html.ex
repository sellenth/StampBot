defmodule DragNStampWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use DragNStampWeb, :html

  embed_templates "page_html/*"
  
  def submitter_stats(timestamps) do
    timestamps
    |> Enum.group_by(& &1.submitter_username)
    |> Enum.map(fn {submitter, timestamps} -> {submitter, length(timestamps)} end)
    |> Enum.sort_by(fn {_submitter, count} -> count end, :desc)
    |> Enum.take(10)
  end
end
