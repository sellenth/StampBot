defmodule DragNStamp.CommenterTest do
  use DragNStamp.DataCase, async: false

  alias DragNStamp.{Commenter, Timestamp}

  test "concurrent stale callers skip the winning pending claim without changing it" do
    timestamp = insert_timestamp()
    parent = self()

    winner =
      Task.async(fn ->
        Commenter.post_for_timestamp(timestamp,
          post_fun: fn _url, _content ->
            send(parent, {:posting, self()})

            receive do
              :finish -> {:ok, %{"id" => "comment-42"}}
            after
              5_000 -> raise "test did not release posting callback"
            end
          end
        )
      end)

    assert_receive {:posting, posting_pid}, 1_000

    callers =
      for _ <- 1..6 do
        Task.async(fn ->
          Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)
        end)
      end

    Enum.each(callers, fn task ->
      assert {:ok, pending, {:skipped, :in_flight}} = Task.await(task)
      assert pending.youtube_comment_status == :pending
      assert pending.youtube_comment_attempts == 1
    end)

    assert Repo.get!(Timestamp, timestamp.id).youtube_comment_status == :pending
    send(posting_pid, :finish)
    assert {:ok, completed, :ok} = Task.await(winner)
    assert completed.youtube_comment_status == :succeeded
    assert completed.youtube_comment_external_id == "comment-42"
    assert completed.youtube_comment_attempts == 1

    assert {:ok, latest, {:skipped, :already_commented}} =
             Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)

    assert latest.youtube_comment_status == :succeeded
    assert Repo.get!(Timestamp, timestamp.id).youtube_comment_attempts == 1
  end

  test "pending, succeeded, and known external comments never change on a skipped call" do
    for attrs <- [
          %{youtube_comment_status: :pending},
          %{youtube_comment_status: :succeeded},
          %{youtube_comment_status: :failed, youtube_comment_external_id: "existing-comment"}
        ] do
      timestamp = insert_timestamp(Map.put(attrs, :youtube_comment_error, "preserve-this-state"))

      assert {:ok, unchanged, {:skipped, _reason}} =
               Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)

      assert unchanged == timestamp
      assert Repo.get!(Timestamp, timestamp.id) == timestamp
    end
  end

  test "a failed claimed post retains its attempt count and stores the normalized error" do
    timestamp = insert_timestamp()

    assert {:ok, updated, {:error, :auth_required}} =
             Commenter.post_for_timestamp(timestamp,
               post_fun: fn _url, _content -> {:error, :unauthorized} end
             )

    assert updated.youtube_comment_status == :auth_required
    assert updated.youtube_comment_error == "auth_required"
    assert updated.youtube_comment_attempts == 1
    assert updated.youtube_comment_last_attempt_at
    assert updated.youtube_comment_dedupe_key
  end

  test "late failure cannot overwrite a reconciled successful claim" do
    timestamp = insert_timestamp()

    assert {:ok, updated, {:skipped, :claim_changed}} =
             Commenter.post_for_timestamp(timestamp,
               post_fun: fn _url, _content ->
                 timestamp
                 |> Timestamp.changeset(%{
                   youtube_comment_status: :succeeded,
                   youtube_comment_external_id: "reconciled-comment",
                   youtube_comment_error: nil
                 })
                 |> Repo.update!()

                 {:error, :quota}
               end
             )

    assert updated.youtube_comment_status == :succeeded
    assert updated.youtube_comment_external_id == "reconciled-comment"
    assert updated.youtube_comment_error == nil
    assert updated.youtube_comment_attempts == 1
  end

  test "cooldown and daily cap reject posts without changing the current status" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {seconds_ago, attempts, reason} <- [{30, 1, :cooldown}, {120, 5, :rate_limited}] do
      timestamp =
        insert_timestamp(%{
          youtube_comment_status: :failed,
          youtube_comment_error: "quota",
          youtube_comment_attempts: attempts,
          youtube_comment_last_attempt_at: DateTime.add(now, -seconds_ago, :second)
        })

      assert {:ok, unchanged, {:error, ^reason}} =
               Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)

      assert unchanged == timestamp
      assert Repo.get!(Timestamp, timestamp.id) == timestamp
    end
  end

  test "a post is eligible again after the daily cap window expires" do
    timestamp =
      insert_timestamp(%{
        youtube_comment_status: :failed,
        youtube_comment_attempts: 5,
        youtube_comment_last_attempt_at:
          DateTime.utc_now() |> DateTime.add(-86_401, :second) |> DateTime.truncate(:second)
      })

    assert {:ok, updated, :ok} =
             Commenter.post_for_timestamp(timestamp,
               post_fun: fn _url, _content -> {:ok, %{"id" => "next-day-comment"}} end
             )

    assert updated.youtube_comment_attempts == 6
    assert updated.youtube_comment_status == :succeeded
  end

  test "interrupted posting leaves a pending claim that is not sent again" do
    timestamp = insert_timestamp()

    assert_raise RuntimeError, "connection interrupted", fn ->
      Commenter.post_for_timestamp(timestamp,
        post_fun: fn _url, _content -> raise "connection interrupted" end
      )
    end

    assert {:ok, pending, {:skipped, :in_flight}} =
             Commenter.post_for_timestamp(timestamp, post_fun: &unexpected_post/2)

    assert pending.youtube_comment_status == :pending
    assert pending.youtube_comment_attempts == 1
  end

  defp unexpected_post(_url, _content), do: flunk("a skipped claim must not post a comment")

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
