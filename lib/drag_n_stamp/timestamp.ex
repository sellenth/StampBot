defmodule DragNStamp.Timestamp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "timestamps" do
    field :url, :string
    field :channel_name, :string
    field :username, :string
    field :submitter_username, :string
    field :content, :string

    timestamps()
  end

  def changeset(timestamp, attrs) do
    timestamp
    |> cast(attrs, [:url, :channel_name, :username, :submitter_username, :content])
    |> validate_required([:url, :channel_name, :username, :submitter_username, :content])
    |> validate_format(:url, ~r/^https?:\/\/.*youtube.*\/watch\?v=.*/, message: "must be a valid YouTube URL")
  end
end