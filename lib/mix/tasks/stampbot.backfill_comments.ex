defmodule Mix.Tasks.Stampbot.BackfillComments do
  use Mix.Task
  @shortdoc "Backfill youtube_comment_status to :succeeded before a cutoff"

  @moduledoc """
  Backfills old timestamps to mark comments as succeeded.

  Usage:
    mix stampbot.backfill_comments --before "2025-08-31T22:14:00Z"

  Options:
    --before       ISO8601 datetime in UTC (e.g., 2025-08-31T22:14:00Z)
    --dry-run      Only print the count; no changes

  Notes:
    - Only updates records where `youtube_comment_status` != :succeeded
    - Clears `youtube_comment_error`
    - Leaves `youtube_comment_external_id` as-is (likely nil)
    - Optionally computes dedupe key when distilled_content present
  """

  require Logger
  import Ecto.Query
  alias DragNStamp.{Repo, Timestamp}

  @chunk 500

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(argv, switches: [before: :string, dry_run: :boolean])

    cutoff =
      case Map.get(opts, :before) do
        nil ->
          Mix.raise("--before is required and must be an ISO8601 UTC timestamp, e.g. 2025-08-31T22:14:00Z")
        iso ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _offset} -> dt
            {:error, reason} -> Mix.raise("Invalid --before datetime: #{inspect(reason)}")
          end
      end

    dry_run? = Map.get(opts, :dry_run, false)

    q =
      from t in Timestamp,
        where: t.inserted_at < ^cutoff and t.youtube_comment_status != ^:succeeded,
        order_by: [asc: t.id]

    total = Repo.aggregate(q, :count, :id)
    Mix.shell().info("Found #{total} records to backfill before #{cutoff}")

    if dry_run? or total == 0 do
      :ok
    else
      backfill_in_chunks(q)
      Mix.shell().info("Backfill complete")
    end
  end

  defp backfill_in_chunks(query) do
    Repo.transaction(fn ->
      stream = Repo.stream(query)
      stream
      |> Stream.chunk_every(@chunk)
      |> Enum.each(&backfill_chunk/1)
    end, timeout: :infinity)
  end

  defp backfill_chunk(records) do
    now = DateTime.utc_now()

    updates =
      Enum.map(records, fn t ->
        dedupe_key = dedupe_key(t)
        %{
          id: t.id,
          youtube_comment_status: :succeeded,
          youtube_comment_error: nil,
          youtube_comment_last_attempt_at: t.youtube_comment_last_attempt_at || now,
          youtube_comment_dedupe_key: dedupe_key,
          youtube_comment_attempts: t.youtube_comment_attempts || 0
        }
      end)

    Enum.each(updates, fn attrs ->
      t = Enum.find(records, &(&1.id == attrs.id))
      changes = struct(Timestamp, Map.from_struct(t))
      |> Timestamp.changeset(attrs)
      case Repo.update(changes) do
        {:ok, _} -> :ok
        {:error, cs} -> Mix.shell().error("Failed to update id=#{t.id}: #{inspect(cs.errors)}")
      end
    end)
  end

  defp dedupe_key(%Timestamp{url: url, distilled_content: content}) when is_binary(url) and is_binary(content) do
    :crypto.hash(:sha256, url <> "|" <> content) |> Base.encode16(case: :lower)
  end
  defp dedupe_key(_), do: nil
end

