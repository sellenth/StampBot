defmodule DragNStamp.PublicationPolicyTest do
  use DragNStamp.DataCase, async: false
  use Oban.Testing, repo: DragNStamp.Repo

  alias DragNStamp.{Commenter, PublicationPolicy, Timestamp}
  alias DragNStamp.PublicationPolicy.Attempt
  alias DragNStamp.Submissions.PublishWorker

  setup do
    keys = [:publication_mode, :publication_daily_limit, :publication_account_key]
    previous = Map.new(keys, fn key -> {key, Application.fetch_env(:drag_n_stamp, key)} end)
    Application.put_env(:drag_n_stamp, :publication_mode, :manual)
    Application.put_env(:drag_n_stamp, :publication_daily_limit, 1)
    Application.put_env(:drag_n_stamp, :publication_account_key, "test-system-account")

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, setting} -> Application.put_env(:drag_n_stamp, key, setting)
          :error -> Application.delete_env(:drag_n_stamp, key)
        end
      end
    end)

    :ok
  end

  test "ordinary direct calls and submission metadata cannot authorize publication" do
    timestamp =
      insert_timestamp(%{
        submitter_username: "operator",
        processing_context: %{"publication_source" => "operator", "authorized" => true}
      })

    assert {:error, :publication_not_authorized} =
             Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)

    for authority <- [nil, :anonymous, "operator", true, :automatic] do
      assert {:error, :publication_not_authorized} =
               PublicationPolicy.enqueue(timestamp, authority)

      assert {:error, :publication_not_authorized} =
               Commenter.post_for_timestamp(timestamp,
                 authority: authority,
                 post_fun: &unexpected_post/2
               )
    end

    assert Repo.aggregate(Attempt, :count) == 0
    refute_enqueued(worker: PublishWorker)
    assert Repo.get!(Timestamp, timestamp.id).youtube_comment_status == :not_attempted
  end

  test "operator jobs carry only an explicit source and approved content digest" do
    timestamp = insert_timestamp()
    assert {:ok, job} = PublicationPolicy.enqueue(timestamp, :operator)
    assert job.args["timestamp_id"] == timestamp.id
    assert job.args["publication_source"] == "operator"
    assert job.args["content_digest"] == PublicationPolicy.content_digest(timestamp)
    assert Enum.sort(Map.keys(job.args)) == ~w(content_digest publication_source timestamp_id)

    assert :ok =
             PublishWorker.perform(job,
               post_fun: fn _url, content ->
                 assert content == timestamp.distilled_content
                 {:ok, %{"id" => "approved-comment"}}
               end
             )

    attempt = Repo.one!(Attempt)
    assert attempt.authority == "operator"
    assert attempt.account_key == "test-system-account"
    assert attempt.status == :succeeded
    assert attempt.external_id == "approved-comment"
  end

  test "content changes after approval cannot publish through the old job" do
    timestamp = insert_timestamp()
    {:ok, job} = PublicationPolicy.enqueue(timestamp, :operator)

    timestamp
    |> Timestamp.changeset(%{distilled_content: "0:00 Changed after approval"})
    |> Repo.update!()

    assert {:cancel, :publication_content_changed} =
             PublishWorker.perform(job, post_fun: &unexpected_post/2)

    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.get!(Timestamp, timestamp.id).youtube_comment_status == :not_attempted
  end

  test "a retained full result is the approved and published content" do
    content = "0:00 Opening\n42:57 Final descent\n\nTimestamps by StampBot"
    timestamp = insert_timestamp(%{distilled_content: nil, content: content})
    assert {:ok, job} = PublicationPolicy.enqueue(timestamp, :operator)
    assert is_binary(job.args["content_digest"])

    assert :ok =
             PublishWorker.perform(job,
               post_fun: fn _, sent ->
                 assert sent == content
                 {:ok, %{"id" => "full-result-comment"}}
               end
             )

    assert Repo.get!(Timestamp, timestamp.id).youtube_comment_status == :succeeded
  end

  test "a retained full result cannot change between approval and publishing" do
    timestamp = insert_timestamp(%{distilled_content: nil, content: "0:00 Approved full result"})
    {:ok, job} = PublicationPolicy.enqueue(timestamp, :operator)
    timestamp |> Timestamp.changeset(%{content: "0:00 Changed full result"}) |> Repo.update!()

    assert {:cancel, :publication_content_changed} =
             PublishWorker.perform(job, post_fun: &unexpected_post/2)

    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "legacy jobs and jobs without scoped approval cannot publish" do
    timestamp = insert_timestamp()

    for args <- [
          %{"timestamp_id" => timestamp.id},
          %{"timestamp_id" => timestamp.id, "publication_source" => "operator"}
        ] do
      assert {:cancel, :publication_not_authorized} =
               PublishWorker.perform(%Oban.Job{args: args}, post_fun: &unexpected_post/2)
    end

    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "automatic publication requires explicit configuration at enqueue and execution" do
    timestamp = insert_timestamp()

    assert {:error, :publication_not_authorized} =
             PublicationPolicy.enqueue(timestamp, :automatic)

    Application.put_env(:drag_n_stamp, :publication_mode, :automatic)
    assert {:ok, job} = PublicationPolicy.enqueue(timestamp, :automatic)
    assert job.args["publication_source"] == "automatic"
    Application.put_env(:drag_n_stamp, :publication_mode, :manual)

    assert {:cancel, :publication_not_authorized} =
             PublishWorker.perform(job, post_fun: &unexpected_post/2)

    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "a pending attempt consumes the account limit across different records and callers" do
    first = insert_timestamp()
    second = insert_timestamp()
    parent = self()

    winner =
      Task.async(fn ->
        Commenter.post_for_timestamp(first,
          authority: :operator,
          post_fun: fn _url, _content ->
            send(parent, {:posting, self()})

            receive do
              :finish -> {:ok, %{"id" => "first-comment"}}
            after
              5_000 -> raise "test did not release posting callback"
            end
          end
        )
      end)

    assert_receive {:posting, posting_pid}, 1_000
    assert Repo.one!(Attempt).status == :pending

    competing =
      Task.async(fn ->
        Commenter.post_for_timestamp(second,
          authority: :operator,
          post_fun: &unexpected_post/2
        )
      end)

    assert {:error, :publication_daily_limit} = Task.await(competing)
    unclaimed = Repo.get!(Timestamp, second.id)
    assert unclaimed.youtube_comment_status == :not_attempted
    assert unclaimed.youtube_comment_attempts == 0
    assert Repo.aggregate(Attempt, :count) == 1
    send(posting_pid, :finish)
    assert {:ok, _completed, :ok} = Task.await(winner)
  end

  test "failed and uncertain sends continue to consume the daily allowance" do
    first = insert_timestamp()
    second = insert_timestamp()

    assert {:ok, _failed, {:error, :quota}} =
             Commenter.post_for_timestamp(first,
               authority: :operator,
               post_fun: fn _url, _content -> {:error, :quota} end
             )

    assert Repo.one!(Attempt).status == :failed

    assert {:error, :publication_daily_limit} =
             Commenter.post_for_timestamp(second,
               authority: :operator,
               post_fun: &unexpected_post/2
             )
  end

  test "yesterday's uncertain attempt does not consume today's allowance" do
    previous = insert_timestamp()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Attempt{
      timestamp_id: previous.id,
      account_key: "test-system-account",
      authority: "operator",
      content_digest: PublicationPolicy.content_digest(previous),
      attempt_number: 1,
      status: :pending,
      attempted_at: DateTime.add(now, -86_400, :second)
    })

    assert {:ok, _completed, :ok} =
             Commenter.post_for_timestamp(insert_timestamp(),
               authority: :operator,
               post_fun: fn _url, _content -> {:ok, %{"id" => "today-comment"}} end
             )

    assert Repo.aggregate(Attempt, :count) == 2
  end

  defp unexpected_post(_url, _content),
    do: flunk("unauthorized or unreserved calls must not publish")

  defp insert_timestamp(attrs \\ %{}) do
    defaults = %{
      url: "https://www.youtube.com/watch?v=#{System.unique_integer([:positive])}",
      channel_name: "Fixture channel",
      submitter_username: "anonymous",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready
    }

    %Timestamp{}
    |> Timestamp.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
