defmodule DragNStamp.Timestamp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "timestamps" do
    field :url, :string
    field :channel_name, :string
    field :submitter_username, :string
    field :content, :string
    field :distilled_content, :string
    field :youtube_comment_posted, :boolean, default: false

    timestamps()
  end

  def changeset(timestamp, attrs) do
    timestamp
    |> cast(attrs, [:url, :channel_name, :submitter_username, :content, :distilled_content, :youtube_comment_posted])
    |> validate_required([:url, :channel_name, :content])
    |> validate_format(:url, ~r/^https?:\/\/(.*youtube.*\/watch\?v=.*|youtu\.be\/.*)/,
      message: "must be a valid YouTube URL"
    )
  end
end
