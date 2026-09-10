defmodule DragNStamp.Timestamps.CaptionCheckpoint do
  @moduledoc "Validated excerpt results, scoped to a submission and exact generation inputs."
  use Ecto.Schema
  import Ecto.Query
  alias DragNStamp.{ProcessingAttempts, Repo}
  alias DragNStamp.Timestamps.{GeminiClient, Prompts, TimestampSet}

  schema "caption_checkpoints" do
    field :timestamp_id, :integer
    field :input_hash, :string
    field :chunk_index, :integer
    field :chapter_data, {:array, :map}
    field :model, :string
    field :model_version, :string
    timestamps(type: :utc_datetime_usec)
  end

  def key(prompt, bounds) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        "caption-checkpoint-v1",
        prompt,
        bounds,
        GeminiClient.text_model(),
        GeminiClient.text_thinking_level(),
        Prompts.system_instruction(),
        TimestampSet.json_schema(bounds)
      })
    )
    |> Base.encode16(case: :lower)
  end

  def fetch(index, hash, bounds) do
    with id when is_integer(id) <- ProcessingAttempts.context()[:timestamp_id],
         %__MODULE__{} = saved <-
           Repo.one(
             from c in __MODULE__,
               where: c.timestamp_id == ^id and c.chunk_index == ^index and c.input_hash == ^hash
           ),
         {:ok, timestamps} <- TimestampSet.validate(saved.chapter_data, bounds),
         false <- Enum.any?(timestamps, &(String.upcase(&1.title) == "UNWATCHED")) do
      {:ok,
       %GeminiClient.Result{
         content: TimestampSet.render(timestamps),
         timestamps: timestamps,
         model: saved.model,
         model_version: saved.model_version,
         duration_ms: 0,
         attempts: 0,
         request_cost_usd: Decimal.new(0),
         cache_hit: true
       }}
    else
      _ -> :miss
    end
  end

  def put(index, hash, %GeminiClient.Result{} = result) do
    if id = ProcessingAttempts.context()[:timestamp_id] do
      now = DateTime.utc_now()

      row = %{
        timestamp_id: id,
        input_hash: hash,
        chunk_index: index,
        chapter_data:
          Enum.map(result.timestamps, &%{"seconds" => &1.seconds, "title" => &1.title}),
        model: result.model,
        model_version: result.model_version,
        inserted_at: now,
        updated_at: now
      }

      Repo.insert_all(__MODULE__, [row],
        conflict_target: [:timestamp_id, :chunk_index],
        on_conflict: {:replace, [:input_hash, :chapter_data, :model, :model_version, :updated_at]}
      )
    end

    :ok
  end
end
