defmodule DragNStamp.Timestamps.SubmissionLimitTest do
  use DragNStamp.DataCase, async: false

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Timestamps.SubmissionLimit

  test "allows the 1,000th timestamp and rejects the 1,001st" do
    insert_timestamps(SubmissionLimit.limit() - 1)

    refute SubmissionLimit.reached?()

    assert {:ok, %Timestamp{}} =
             SubmissionLimit.insert_if_available(
               timestamp_changeset("https://www.youtube.com/watch?v=boundary1000")
             )

    assert SubmissionLimit.reached?()

    assert {:error, :submission_limit_reached} =
             SubmissionLimit.insert_if_available(
               timestamp_changeset("https://www.youtube.com/watch?v=blocked1001")
             )

    assert Repo.aggregate(Timestamp, :count, :id) == SubmissionLimit.limit()
  end

  defp insert_timestamps(count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for index <- 1..count do
        %{
          url: "https://www.youtube.com/watch?v=limit#{index}",
          channel_name: "Limit Test",
          submitter_username: "anonymous",
          content: "0:00 Intro",
          distilled_content: "0:00 Intro",
          processing_status: :ready,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Timestamp, rows)
  end

  defp timestamp_changeset(url) do
    Timestamp.changeset(%Timestamp{}, %{
      url: url,
      channel_name: "Limit Test",
      submitter_username: "anonymous",
      processing_status: :processing
    })
  end
end
