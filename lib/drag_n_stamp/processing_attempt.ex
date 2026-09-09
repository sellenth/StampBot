defmodule DragNStamp.ProcessingAttempt do
  @moduledoc "A durable, payload-free record of one run, stage, chunk, or provider request."
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(timestamp_id parent_attempt_id job_id job_attempt reservation_id run_id kind stage
    status provider operation chunk_index request_attempt started_at finished_at duration_ms
    failure_kind http_status dispatched model model_version thinking_level prompt_version schema_version
    provider_request_id finish_reason input_bytes start_seconds end_seconds prompt_tokens output_tokens
    thinking_tokens cached_tokens total_tokens usage_status cost_status estimated_cost_usd)a

  schema "processing_attempts" do
    belongs_to :timestamp, DragNStamp.Timestamp
    belongs_to :parent_attempt, __MODULE__
    field :job_id, :integer
    field :job_attempt, :integer
    field :reservation_id, :integer
    field :run_id, Ecto.UUID
    field :kind, Ecto.Enum, values: [:run, :stage, :chunk, :request]
    field :stage, :string
    field :status, Ecto.Enum, values: [:running, :succeeded, :failed, :interrupted]
    field :provider, :string
    field :operation, :string
    field :chunk_index, :integer
    field :request_attempt, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :failure_kind, :string
    field :http_status, :integer
    field :dispatched, :boolean, default: false
    field :model, :string
    field :model_version, :string
    field :thinking_level, :string
    field :prompt_version, :string
    field :schema_version, :string
    field :provider_request_id, :string
    field :finish_reason, :string
    field :input_bytes, :integer
    field :start_seconds, :integer
    field :end_seconds, :integer
    field :prompt_tokens, :integer
    field :output_tokens, :integer
    field :thinking_tokens, :integer
    field :cached_tokens, :integer
    field :total_tokens, :integer

    field :usage_status, Ecto.Enum,
      values: [:not_reported, :reported, :partial],
      default: :not_reported

    field :cost_status, Ecto.Enum,
      values: [:not_applicable, :not_dispatched, :unknown, :estimated],
      default: :not_applicable

    field :estimated_cost_usd, :decimal
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, @fields)
    |> validate_required([:timestamp_id, :run_id, :kind, :stage, :status, :started_at])
    |> validate_inclusion(
      :stage,
      ~w(processing metadata video captions caption_acquisition caption_chunk distillation)
    )
    |> validate_inclusion(:provider, ~w(gemini youtube local))
    |> validate_inclusion(:operation, ~w(video text))
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_usd, greater_than_or_equal_to: 0)
    |> validate_length(:provider_request_id, max: 255)
    |> validate_length(:model, max: 128)
    |> validate_length(:model_version, max: 128)
    |> validate_length(:prompt_version, max: 64)
    |> validate_length(:schema_version, max: 64)
    |> foreign_key_constraint(:timestamp_id)
  end
end
