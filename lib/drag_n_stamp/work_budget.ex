defmodule DragNStamp.WorkBudget do
  @moduledoc """
  Atomic work limits and conservative USD allowance reservations.

  Dollar reservations are operator-configured allowances, not a provider billing
  guarantee. Request/admission/input limits are hard application bounds. Unknown
  outcomes never release an allowance; unused allowance expires at UTC midnight.
  """
  import Ecto.Query
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Security.Caller

  defmodule Reservation do
    use Ecto.Schema

    schema "work_reservations" do
      field :timestamp_id, :id
      field :video_id, :string
      field :caller_hash, :string
      field :allowance_day, :date
      field :remaining_microusd, :integer
      field :request_count, :integer, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Day do
    use Ecto.Schema
    @primary_key {:day, :date, autogenerate: false}
    schema "work_budget_days" do
      field :reserved_microusd, :integer, default: 0
      field :request_count, :integer, default: 0
      field :submission_count, :integer, default: 0
    end
  end

  @defaults [
    enabled: true,
    caller_hourly_limit: 3,
    video_cooldown_seconds: 1800,
    daily_submission_limit: 50,
    daily_request_limit: 200,
    run_request_limit: 32,
    daily_budget_microusd: 25_000_000,
    total_budget_microusd: 25_000_000,
    initial_allowance_microusd: 1_500_000,
    video_request_microusd: 1_500_000,
    text_request_microusd: 500_000,
    max_duration_seconds: 21_600,
    max_caption_chunks: 24,
    max_transcript_bytes: 2_000_000,
    max_request_bytes: 262_144
  ]

  def config(key),
    do:
      Keyword.get(
        Application.get_env(:drag_n_stamp, :work_budget, []),
        key,
        Keyword.fetch!(@defaults, key)
      )

  def enabled?, do: config(:enabled)

  @doc "Called inside the same transaction as submission acceptance and job insertion."
  def reserve!(timestamp, opts \\ []) do
    if enabled?() do
      unless Repo.in_transaction?(),
        do: raise(ArgumentError, "work reservation requires an acceptance transaction")

      lock!()
      now = DateTime.utc_now()
      day = day!(DateTime.to_date(now))
      total_reserved = total_reserved_microusd()
      caller = Keyword.get(opts, :caller_hash, Caller.internal())
      video_id = timestamp.video_id || timestamp.url
      cutoff = DateTime.add(now, -3600, :second)

      recent =
        Repo.aggregate(
          from(r in Reservation, where: r.caller_hash == ^caller and r.inserted_at > ^cutoff),
          :count
        )

      cooldown = DateTime.add(now, -config(:video_cooldown_seconds), :second)

      cond do
        recent >= config(:caller_hourly_limit) ->
          Repo.rollback(:caller_rate_limited)

        Repo.exists?(
          from r in Reservation, where: r.video_id == ^video_id and r.inserted_at > ^cooldown
        ) ->
          Repo.rollback(:video_cooldown)

        day.submission_count >= config(:daily_submission_limit) ->
          Repo.rollback(:daily_work_limit)

        total_reserved + config(:initial_allowance_microusd) > config(:total_budget_microusd) ->
          Repo.rollback(:total_budget_exceeded)

        day.reserved_microusd + config(:initial_allowance_microusd) >
            config(:daily_budget_microusd) ->
          Repo.rollback(:daily_budget_exceeded)

        true ->
          :ok
      end

      allowance = config(:initial_allowance_microusd)

      reservation =
        Repo.insert!(%Reservation{
          timestamp_id: timestamp.id,
          video_id: timestamp.video_id || timestamp.url,
          caller_hash: caller,
          allowance_day: day.day,
          remaining_microusd: allowance
        })

      Repo.update_all(from(d in Day, where: d.day == ^day.day),
        inc: [reserved_microusd: allowance, submission_count: 1]
      )

      context =
        Map.put(timestamp.processing_context || %{}, "work_reservation_id", reservation.id)

      timestamp |> Timestamp.changeset(%{processing_context: context}) |> Repo.update!()
    else
      timestamp
    end
  end

  @doc "Reserves legacy processing work before it can issue paid requests."
  def ensure_reservation(timestamp) do
    if enabled?() do
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "submission:" <> (timestamp.video_id || timestamp.url)
        ])

        latest = Repo.get!(Timestamp, timestamp.id)
        id = (latest.processing_context || %{})["work_reservation_id"]

        if id &&
             Repo.exists?(
               from r in Reservation, where: r.id == ^id and r.timestamp_id == ^latest.id
             ),
           do: latest,
           else: reserve!(latest)
      end)
    else
      {:ok, timestamp}
    end
  end

  @doc "Every dispatched provider attempt, including retries, must claim work first."
  def before_request(context) when not is_map(context), do: before_request(%{})

  def before_request(context) do
    cond do
      not enabled?() ->
        :ok

      not is_integer(context[:timestamp_id]) or not is_integer(context[:reservation_id]) ->
        {:error, :work_budget_exceeded}

      true ->
        case Repo.transaction(fn ->
               lock!()

               reservation =
                 context[:reservation_id] && Repo.get(Reservation, context[:reservation_id])

               unless reservation && reservation.timestamp_id == context[:timestamp_id],
                 do: Repo.rollback(:work_budget_exceeded)

               day = day!(Date.utc_today())

               allowance =
                 if context[:operation] == :video,
                   do: config(:video_request_microusd),
                   else: config(:text_request_microusd)

               remaining =
                 if reservation.allowance_day == day.day,
                   do: reservation.remaining_microusd,
                   else: 0

               extra = max(allowance - remaining, 0)

               if total_reserved_microusd() + extra > config(:total_budget_microusd),
                 do: Repo.rollback(:total_budget_exceeded)

               if reservation.request_count >= config(:run_request_limit) or
                    day.request_count >= config(:daily_request_limit) or
                    day.reserved_microusd + extra > config(:daily_budget_microusd),
                  do: Repo.rollback(:work_budget_exceeded)

               Repo.update_all(from(r in Reservation, where: r.id == ^reservation.id),
                 set: [allowance_day: day.day, remaining_microusd: max(remaining - allowance, 0)],
                 inc: [request_count: 1]
               )

               Repo.update_all(from(d in Day, where: d.day == ^day.day),
                 inc: [reserved_microusd: extra, request_count: 1]
               )

               :ok
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def check_duration(_context, nil), do: :ok

  def check_duration(_context, seconds),
    do: bounded(is_number(seconds) and seconds > 0 and seconds <= config(:max_duration_seconds))

  def check_chunks(_context, count),
    do: bounded(is_integer(count) and count <= config(:max_caption_chunks))

  def check_request(_context, body),
    do: bounded(byte_size(Jason.encode!(body)) <= config(:max_request_bytes))

  def check_transcript(context, segments) do
    if enabled?() do
      Enum.reduce_while(segments, 0, fn segment, size ->
        text = Map.get(segment, :text, "")
        next = size + 64 + if(is_binary(text), do: byte_size(text), else: 0)
        if next > config(:max_transcript_bytes), do: {:halt, :too_large}, else: {:cont, next}
      end)
      |> case do
        :too_large ->
          {:error, :input_limit_exceeded}

        _ ->
          ending =
            Enum.reduce(segments, 0, fn s, acc ->
              ending = Map.get(s, :end_ms)
              if(is_number(ending), do: max(acc, ending), else: acc)
            end)

          check_duration(context, max(ending / 1000, 1))
      end
    else
      :ok
    end
  end

  def retry_after(reason) when reason in [:daily_work_limit, :daily_budget_exceeded] do
    now = DateTime.utc_now()
    next_day = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")
    max(DateTime.diff(next_day, now, :second), 1)
  end

  def retry_after(:video_cooldown), do: config(:video_cooldown_seconds)
  def retry_after(_), do: 3600

  def message(:caller_rate_limited),
    do: "Too many submissions from this connection. Please try again in an hour."

  def message(:video_cooldown),
    do: "This video was recently processed. Please wait before retrying."

  def message(:daily_work_limit),
    do: "StampBot has reached today's processing limit. Please try tomorrow."

  def message(:daily_budget_exceeded),
    do: "StampBot has reserved today's processing budget. Please try tomorrow."

  def message(:total_budget_exceeded),
    do:
      "StampBot has reached its total processing budget. Processing is paused until the operator raises the limit."

  def message(:work_budget_exceeded), do: "This submission reached its processing allowance."

  def message(:input_limit_exceeded),
    do: "This video or transcript exceeds StampBot's processing limits."

  def message(_), do: "StampBot could not reserve processing work. Please try later."

  @doc "Cumulative non-refundable allowance, including every previous UTC day."
  def total_reserved_microusd do
    case Repo.aggregate(Day, :sum, :reserved_microusd) do
      nil -> 0
      %Decimal{} = total -> Decimal.to_integer(total)
      total when is_integer(total) -> total
    end
  end

  defp bounded(valid),
    do: if(not enabled?() or valid, do: :ok, else: {:error, :input_limit_exceeded})

  defp lock!,
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "stampbot-work-budget"
      ])

  defp day!(date) do
    Repo.insert!(%Day{day: date}, on_conflict: :nothing)
    Repo.get!(Day, date)
  end
end
