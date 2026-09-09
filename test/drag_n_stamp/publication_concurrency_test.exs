defmodule DragNStamp.PublicationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias DragNStamp.{Commenter, Repo, Timestamp}
  alias DragNStamp.PublicationPolicy.Attempt

  test "independent connections race for the final account allowance before network IO" do
    account = "publication-race-" <> random_video_id()
    video_ids = Enum.map(1..3, fn _ -> random_video_id() end)
    keys = [:publication_mode, :publication_daily_limit, :publication_account_key]
    previous = Map.new(keys, fn key -> {key, Application.fetch_env(:drag_n_stamp, key)} end)

    Application.put_env(:drag_n_stamp, :publication_mode, :manual)
    Application.put_env(:drag_n_stamp, :publication_daily_limit, 2)
    Application.put_env(:drag_n_stamp, :publication_account_key, account)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, setting} -> Application.put_env(:drag_n_stamp, key, setting)
          :error -> Application.delete_env(:drag_n_stamp, key)
        end
      end

      # Only this fixture's random account and videos commit outside the sandbox.
      unboxed(fn ->
        Repo.transaction(fn ->
          Repo.delete_all(from a in Attempt, where: a.account_key == ^account)
          Repo.delete_all(from t in Timestamp, where: t.video_id in ^video_ids)
        end)
      end)
    end)

    [previously_posted | candidates] =
      unboxed(fn -> Enum.map(video_ids, &insert_timestamp/1) end)

    unboxed(fn ->
      assert {:ok, _, :ok} =
               Commenter.post_for_timestamp(previously_posted,
                 authority: :operator,
                 post_fun: fn _, _ -> {:ok, %{"id" => "previous-comment"}} end
               )
    end)

    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(candidates, fn timestamp ->
        Task.async(fn ->
          # Each process owns a real PostgreSQL connection. There is no outer
          # sandbox transaction: Commenter must commit its claim before posting.
          unboxed(fn ->
            %{rows: [[backend_pid]]} =
              Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])

            send(parent, {:ready, barrier, self(), backend_pid})

            receive do
              {:go, ^barrier} -> :ok
            after
              5_000 -> raise "publication race barrier was never released"
            end

            outcome =
              Commenter.post_for_timestamp(timestamp,
                authority: :operator,
                post_fun: fn _, _ ->
                  refute Repo.in_transaction?()
                  send(parent, {:posting, barrier, self(), timestamp.id})

                  receive do
                    {:finish, ^barrier} -> {:ok, %{"id" => "winning-comment"}}
                  after
                    5_000 -> raise "publication callback was never released"
                  end
                end
              )

            send(parent, {:outcome, barrier, timestamp.id, outcome})
            outcome
          end)
        end)
      end)

    try do
      backends =
        Enum.map(tasks, fn task ->
          pid = task.pid
          assert_receive {:ready, ^barrier, ^pid, backend_pid}, 5_000
          backend_pid
        end)

      assert length(Enum.uniq(backends)) == 2
      Enum.each(tasks, &send(&1.pid, {:go, barrier}))

      assert_receive {:posting, ^barrier, posting_pid, winner_id}, 5_000

      assert_receive {:outcome, ^barrier, loser_id, {:error, :publication_daily_limit}},
                     5_000

      assert loser_id != winner_id
      refute_receive {:posting, ^barrier, _, _}, 100

      # The competitor finishes while the winning network call is still held.
      # This proves the account lock and pending ledger row were committed first.
      unboxed(fn ->
        assert Repo.aggregate(from(a in Attempt, where: a.account_key == ^account), :count) == 2

        assert Repo.one!(from(a in Attempt, where: a.timestamp_id == ^winner_id)).status ==
                 :pending

        loser = Repo.get!(Timestamp, loser_id)
        assert loser.youtube_comment_status == :not_attempted
        assert loser.youtube_comment_attempts == 0
      end)

      send(posting_pid, {:finish, barrier})
      results = Task.await_many(tasks, 5_000)
      assert Enum.count(results, &match?({:ok, _, :ok}, &1)) == 1
      assert Enum.count(results, &match?({:error, :publication_daily_limit}, &1)) == 1

      unboxed(fn ->
        attempts = Repo.all(from a in Attempt, where: a.account_key == ^account)
        assert length(attempts) == 2
        assert Enum.all?(attempts, &(&1.status == :succeeded))
        assert Repo.get!(Timestamp, winner_id).youtube_comment_external_id == "winning-comment"
      end)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp insert_timestamp(video_id) do
    %Timestamp{}
    |> Timestamp.changeset(%{
      video_id: video_id,
      url: "https://www.youtube.com/watch?v=#{video_id}",
      channel_name: "Fixture channel",
      submitter_username: "anonymous",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready
    })
    |> Repo.insert!()
  end

  defp random_video_id do
    :crypto.strong_rand_bytes(9)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 11)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
