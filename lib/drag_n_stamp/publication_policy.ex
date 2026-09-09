defmodule DragNStamp.PublicationPolicy.Attempt do
  @moduledoc false
  use Ecto.Schema

  schema "publication_attempts" do
    belongs_to :timestamp, DragNStamp.Timestamp
    field :account_key, :string
    field :authority, :string
    field :content_digest, :string
    field :attempt_number, :integer

    field :status, Ecto.Enum,
      values: [:pending, :succeeded, :failed, :auth_required],
      default: :pending

    field :attempted_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :external_id, :string
    field :error, :string

    timestamps(type: :utc_datetime)
  end
end

defmodule DragNStamp.PublicationPolicy do
  @moduledoc """
  Controls use of the system's YouTube publishing credentials.

  Operator authority is an internal capability: callers must authenticate an
  operator before passing `:operator`. Never derive authority from submission
  parameters. Automatic publication requires an explicit deployment setting.
  Ordinary Commenter calls have no authority and are denied.

  Every claimed network attempt, including a failed or uncertain send, consumes
  the configured account's UTC-day allowance. The short account transaction
  commits the allowance and timestamp claim before any external IO starts.
  """

  import Ecto.Query

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.PublicationPolicy.Attempt
  alias DragNStamp.Submissions.PublishWorker

  def authorize(:operator), do: :ok

  def authorize(:automatic) do
    if Application.get_env(:drag_n_stamp, :publication_mode, :manual) == :automatic,
      do: :ok,
      else: {:error, :publication_not_authorized}
  end

  def authorize(_), do: {:error, :publication_not_authorized}

  def source("operator"), do: :operator
  def source("automatic"), do: :automatic
  def source(_), do: nil

  def enqueue(%Timestamp{id: id}, authority) when not is_nil(id) do
    with :ok <- authorize(authority),
         %Timestamp{} = timestamp <- Repo.get(Timestamp, id),
         :ok <- enqueue_eligibility(timestamp) do
      %{
        "timestamp_id" => timestamp.id,
        "publication_source" => Atom.to_string(authority),
        "content_digest" => content_digest(timestamp)
      }
      |> PublishWorker.new()
      |> Oban.insert()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def enqueue(_, _), do: {:error, :not_found}

  def content_digest(%Timestamp{url: url, distilled_content: content})
      when is_binary(url) and is_binary(content) do
    :crypto.hash(:sha256, url <> "|" <> content) |> Base.encode16(case: :lower)
  end

  def content_digest(_), do: nil

  @doc false
  def claim(authority, claim_fun) when is_function(claim_fun, 0) do
    with :ok <- authorize(authority) do
      Repo.transaction(fn ->
        account = account_key()

        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["publication-account:" <> account]
        )

        case claim_fun.() do
          {:ok, timestamp} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)
            start_of_day = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
            end_of_day = DateTime.add(start_of_day, 86_400, :second)

            attempted =
              Repo.aggregate(
                from(a in Attempt,
                  where:
                    a.account_key == ^account and a.attempted_at >= ^start_of_day and
                      a.attempted_at < ^end_of_day
                ),
                :count
              )

            if attempted >= daily_limit(), do: Repo.rollback(:publication_daily_limit)

            attempt =
              Repo.insert!(%Attempt{
                timestamp_id: timestamp.id,
                account_key: account,
                authority: Atom.to_string(authority),
                content_digest: content_digest(timestamp),
                attempt_number: timestamp.youtube_comment_attempts,
                status: :pending,
                attempted_at: now
              })

            {timestamp, attempt}

          other ->
            Repo.rollback({:claim_rejected, other})
        end
      end)
      |> case do
        {:ok, {timestamp, attempt}} -> {:ok, timestamp, attempt}
        {:error, {:claim_rejected, result}} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def finish_attempt!(%Attempt{} = attempt, %Timestamp{} = timestamp) do
    attempt
    |> Ecto.Changeset.change(%{
      status: timestamp.youtube_comment_status,
      external_id: timestamp.youtube_comment_external_id,
      error: timestamp.youtube_comment_error,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp enqueue_eligibility(%Timestamp{} = timestamp) do
    cond do
      timestamp.youtube_comment_status == :succeeded or
          not is_nil(timestamp.youtube_comment_external_id) ->
        {:error, :already_published}

      timestamp.youtube_comment_status == :pending ->
        {:error, :publication_in_flight}

      timestamp.processing_status != :ready or not is_binary(timestamp.distilled_content) or
          String.trim(timestamp.distilled_content) == "" ->
        {:error, :submission_not_ready}

      String.contains?(timestamp.distilled_content, "0:00 UNWATCHED") ->
        {:error, :submission_not_ready}

      true ->
        :ok
    end
  end

  defp account_key do
    case Application.get_env(:drag_n_stamp, :publication_account_key, "system") do
      account when is_binary(account) and byte_size(account) > 0 -> account
      _ -> "system"
    end
  end

  defp daily_limit do
    case Application.get_env(:drag_n_stamp, :publication_daily_limit, 10) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _ -> 0
    end
  end
end
