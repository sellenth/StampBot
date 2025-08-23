defmodule DragNStampWeb.LeaderboardLive do
  use DragNStampWeb, :live_view
  alias DragNStamp.{Repo, Timestamp}
  import Ecto.Query
  require Logger

  @topic "timestamps"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DragNStamp.PubSub, @topic)
    end

    timestamps =
      Timestamp
      |> order_by(desc: :inserted_at)
      |> Repo.all()

    {:ok,
     assign(socket,
       timestamps: timestamps,
       page_title: "Timestamp Leaderboard | Top YouTube Content Creators & Contributors",
       page_description:
         "Discover the most active YouTube timestamp contributors and popular channels. See who's creating the most AI-generated video chapters and top performing content."
     )}
  end

  def handle_info({:timestamp_created, timestamp}, socket) do
    Logger.info("Received new timestamp via PubSub: #{timestamp.id}")

    updated_timestamps = [timestamp | socket.assigns.timestamps]

    {:noreply,
     socket
     |> assign(:timestamps, updated_timestamps)
     |> put_flash(:info, "New timestamp added by #{timestamp.submitter_username}!")}
  end

  defp submitter_stats(timestamps) do
    timestamps
    |> Enum.group_by(& &1.submitter_username)
    |> Enum.map(fn {submitter, list} ->
      {submitter, length(list), List.first(list).inserted_at}
    end)
    |> Enum.sort_by(fn {_, count, _} -> count end, :desc)
  end

  defp channel_stats(timestamps) do
    timestamps
    |> Enum.group_by(& &1.channel_name)
    |> Enum.map(fn {channel, list} ->
      {channel, length(list)}
    end)
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(10)
  end

  defp recent_activity(timestamps) do
    timestamps
    |> Enum.take(5)
  end

  defp total_timestamps(timestamps) do
    length(timestamps)
  end

  defp unique_contributors(timestamps) do
    timestamps
    |> Enum.map(& &1.submitter_username)
    |> Enum.uniq()
    |> length()
  end
end
