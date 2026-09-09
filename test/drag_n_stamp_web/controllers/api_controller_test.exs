defmodule DragNStampWeb.ApiControllerTest do
  use DragNStampWeb.ConnCase, async: false

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Timestamps.SubmissionLimit

  test "rejects a new submission when the timestamp cap is reached", %{conn: conn} do
    insert_timestamps(SubmissionLimit.limit())

    conn =
      post(conn, ~p"/api/gemini", %{
        "url" => "https://www.youtube.com/watch?v=oneTooMany1",
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

  test "accepts a durable job and exposes its status without running a provider", %{conn: conn} do
    conn = post(conn, ~p"/api/gemini", %{"url" => "https://youtu.be/abc123xyz89?t=30"})

    assert %{"status" => "processing", "timestamp_id" => id, "status_url" => status_url} =
             json_response(conn, 202)

    assert Repo.get!(Timestamp, id).url == "https://www.youtube.com/watch?v=abc123xyz89"
    assert get_resp_header(conn, "location") == [status_url]

    assert Repo.get_by!(Oban.Job, worker: "DragNStamp.Submissions.Worker").args == %{
             "timestamp_id" => id
           }

    status_conn = get(recycle(conn), status_url)

    assert %{"status" => "processing", "phase" => "queued", "timestamp_id" => ^id} =
             json_response(status_conn, 200)
  end

  test "invalid inputs return useful 400 responses without creating records", %{conn: conn} do
    for value <- [
          nil,
          123,
          "https://youtube.com.evil.example/watch?v=abc123xyz89",
          "https://youtu.be/short"
        ] do
      response = post(conn, ~p"/api/gemini", %{"url" => value})
      assert %{"reason" => "invalid_url"} = json_response(response, 400)
    end

    assert Repo.aggregate(Timestamp, :count) == 0
  end

  test "status endpoint handles missing and malformed IDs", %{conn: conn} do
    assert json_response(get(conn, "/api/submissions/not-an-id"), 404)["status"] == "error"
    assert json_response(get(conn, "/api/submissions/999999999"), 404)["status"] == "error"

    assert json_response(get(conn, "/api/submissions/999999999999999999999999"), 404)["status"] ==
             "error"
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
