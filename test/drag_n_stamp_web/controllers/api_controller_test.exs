defmodule DragNStampWeb.ApiControllerTest do
  use DragNStampWeb.ConnCase, async: false

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Timestamps.SubmissionLimit

  test "rejects a new submission when the timestamp cap is reached", %{conn: conn} do
    insert_timestamps(SubmissionLimit.limit())

    conn =
      post(conn, ~p"/api/gemini", %{
        "url" => "https://www.youtube.com/watch?v=oneTooMany",
        "channel_name" => "Limit Test"
      })

    assert %{
             "status" => "error",
             "reason" => "submission_limit_reached",
             "message" => message,
             "limit" => 1_000
           } = json_response(conn, 503)

    assert message == SubmissionLimit.message()
    assert Repo.aggregate(Timestamp, :count, :id) == SubmissionLimit.limit()
  end

  defp insert_timestamps(count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for index <- 1..count do
        %{
          url: "https://www.youtube.com/watch?v=apiLimit#{index}",
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
end
