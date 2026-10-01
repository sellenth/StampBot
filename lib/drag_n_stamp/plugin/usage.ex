defmodule DragNStamp.Plugin.Usage.Event do
  @moduledoc false
  use Ecto.Schema

  schema "plugin_usage_events" do
    field :request_key, Ecto.UUID
    field :operation, :string
    field :outcome, :string
    field :reason, :string
    field :actor_hash, :string
    field :identity_kind, :string
    field :session_hash, :string
    field :transport_hash, :string
    field :new_work, :boolean, default: false
    field :elapsed_ms, :integer, default: 0
    belongs_to :timestamp, DragNStamp.Timestamp
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule DragNStamp.Plugin.Usage do
  @moduledoc "Plugin admission and usage measurement without raw client identifiers or prompts."
  import Ecto.Query
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Plugin.Usage.Event
  alias DragNStamp.Security.Caller

  @defaults [
    enabled: true,
    daily_new_jobs: 20,
    actor_daily_new_jobs: 3,
    transport_hourly_new_jobs: 10
  ]

  def config(key),
    do:
      Keyword.get(
        Application.get_env(:drag_n_stamp, :plugin, []),
        key,
        Keyword.fetch!(@defaults, key)
      )

  def context(conn, meta) do
    meta = if is_map(meta), do: meta, else: %{}
    transport = Caller.from_connection(conn.remote_ip, conn.req_headers)
    subject = identifier(meta["openai/subject"])
    session = identifier(meta["openai/session"])

    %{
      request_key: Ecto.UUID.generate(),
      actor_hash: if(subject, do: hash("subject", subject), else: hash("transport", transport)),
      identity_kind: if(subject, do: "subject", else: "transport"),
      session_hash: if(session, do: hash("session", session)),
      transport_hash: hash("transport", transport),
      caller_hash: if(subject, do: "plugin:" <> hash("subject", subject), else: transport),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc "Atomic with the submission and work reservation; cached and active jobs skip this hook."
  def admit!(timestamp, context) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "plugin admission requires a transaction")

    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "stampbot-plugin-admission"
    ])

    now = DateTime.utc_now()
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    hour = DateTime.add(now, -3_600, :second)
    day_jobs = from e in Event, where: e.new_work and e.inserted_at >= ^midnight

    cond do
      Repo.aggregate(day_jobs, :count) >= config(:daily_new_jobs) ->
        Repo.rollback(:plugin_daily_limit)

      Repo.aggregate(from(e in day_jobs, where: e.actor_hash == ^context.actor_hash), :count) >=
          config(:actor_daily_new_jobs) ->
        Repo.rollback(:plugin_actor_limit)

      Repo.aggregate(
        from(e in Event,
          where:
            e.new_work and e.transport_hash == ^context.transport_hash and e.inserted_at >= ^hour
        ),
        :count
      ) >= config(:transport_hourly_new_jobs) ->
        Repo.rollback(:plugin_transport_limit)

      true ->
        :ok
    end

    # ChatGPT subject/session metadata are rate-limit and analytics hints, never
    # authentication. The independent transport and global limits bound spoofing.
    timestamp =
      timestamp
      |> Timestamp.changeset(%{
        processing_context:
          Map.merge(timestamp.processing_context || %{}, %{
            "submission_source" => "chatgpt_plugin",
            "disable_automatic_publication" => true
          })
      })
      |> Repo.update!()

    record(context, "generate_chapters", "processing", timestamp.id, new_work: true)
    timestamp
  end

  def record(context, operation, outcome, timestamp_id, opts \\ []) do
    event =
      struct(
        Event,
        Map.take(context, [
          :request_key,
          :actor_hash,
          :identity_kind,
          :session_hash,
          :transport_hash
        ])
      )

    attrs = %{
      operation: operation,
      outcome: outcome,
      timestamp_id: timestamp_id,
      new_work: Keyword.get(opts, :new_work, false),
      reason: Keyword.get(opts, :reason),
      elapsed_ms: max(System.monotonic_time(:millisecond) - context.started_at, 0)
    }

    event
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict: [set: Map.to_list(Map.take(attrs, [:outcome, :reason, :elapsed_ms]))],
      conflict_target: :request_key
    )
  end

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256, do: value
  defp identifier(_), do: nil

  defp hash(kind, value) do
    secret = DragNStampWeb.Endpoint.config(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, "stampbot-plugin:" <> kind <> ":" <> value)
    |> Base.encode16(case: :lower)
  end
end
