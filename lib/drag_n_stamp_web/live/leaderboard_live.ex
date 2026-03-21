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

    {:ok,
     assign(socket,
       timestamps: load_timestamps(),
       page_title: "Timestamp Leaderboard | Top YouTube Content Creators & Contributors",
       page_description:
         "Discover the most active YouTube timestamp contributors and popular channels. See who's creating the most AI-generated video chapters and top performing content."
     )}
  end

  def handle_info({:timestamp_created, timestamp}, socket) do
    Logger.info("Received new timestamp via PubSub: #{timestamp.id}")

    {:noreply,
     socket
     |> assign(:timestamps, [timestamp | socket.assigns.timestamps])
     |> put_flash(:info, "New timestamp added by #{timestamp.submitter_username}!")}
  end

  def handle_info({:timestamp_updated, timestamp}, socket) do
    timestamps = socket.assigns.timestamps

    updated_list =
      if Enum.any?(timestamps, &(&1.id == timestamp.id)) do
        Enum.map(timestamps, fn t -> if t.id == timestamp.id, do: timestamp, else: t end)
      else
        [timestamp | timestamps]
      end

    {:noreply, assign(socket, :timestamps, updated_list)}
  end

  defp load_timestamps do
    Timestamp
    |> order_by(desc: :inserted_at)
    |> Repo.all()
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

  defp recent_activity(timestamps), do: Enum.take(timestamps, 5)
  defp total_timestamps(timestamps), do: length(timestamps)

  defp unique_contributors(timestamps) do
    timestamps
    |> Enum.map(& &1.submitter_username)
    |> Enum.uniq()
    |> length()
  end
end
