defmodule DragNStampWeb.OperatorControllerTest do
  use DragNStampWeb.ConnCase, async: false
  use Oban.Testing, repo: DragNStamp.Repo
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Submissions.PublishWorker

  @token "offline-operator-test-token-at-least-32-bytes"

  setup do
    previous = Application.get_env(:drag_n_stamp, :operator_token)
    Application.put_env(:drag_n_stamp, :operator_token, @token)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :operator_token, previous) end)

    ts =
      %Timestamp{}
      |> Timestamp.changeset(%{
        url: "https://www.youtube.com/watch?v=operator001",
        channel_name: "test",
        content: "0:00 Intro",
        distilled_content: "0:00 Intro",
        processing_status: :ready
      })
      |> Repo.insert!()

    %{timestamp: ts}
  end

  test "public and forged authority parameters cannot enqueue account writes", %{
    conn: conn,
    timestamp: ts
  } do
    for headers <- [[], [{"authorization", "Bearer incorrect"}]] do
      request =
        Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)

      assert json_response(
               post(request, "/api/operator/submissions/#{ts.id}/publish", %{
                 authority: "operator",
                 token: @token
               }),
               401
             )["status"] == "error"
    end

    refute_enqueued(worker: PublishWorker)
  end

  test "authenticated operators queue only a content-bound job with no credential", %{
    conn: conn,
    timestamp: ts
  } do
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> post("/api/operator/submissions/#{ts.id}/publish")

    assert %{"status" => "accepted", "submission_id" => id} = json_response(response, 202)
    assert id == ts.id
    assert [job] = all_enqueued(worker: PublishWorker)
    assert job.args["publication_source"] == "operator"
    assert byte_size(job.args["content_digest"]) == 64
    refute inspect(job.args) =~ @token
    assert Repo.get!(Timestamp, ts.id).youtube_comment_attempts == 0
  end

  test "missing and weak operator configuration fail closed", %{conn: conn, timestamp: ts} do
    for configured <- [nil, "short"] do
      Application.put_env(:drag_n_stamp, :operator_token, configured)

      response =
        conn
        |> put_req_header("authorization", "Bearer " <> (configured || @token))
        |> post("/api/operator/submissions/#{ts.id}/publish")

      assert json_response(response, 401)["status"] == "error"
    end

    refute_enqueued(worker: PublishWorker)
  end

  test "authenticated malformed IDs are handled without exception", %{conn: conn} do
    response =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> post("/api/operator/submissions/9999999999999999999999/publish")

    assert json_response(response, 404)["status"] == "error"
  end
end
