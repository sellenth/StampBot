defmodule DragNStampWeb.SubmissionLimitsTest do
  use DragNStampWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.WorkBudget.Reservation
  alias DragNStamp.Security.Caller

  setup do
    previous = Application.get_env(:drag_n_stamp, :work_budget)
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true, caller_hourly_limit: 1)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :work_budget, previous) end)
    :ok
  end

  test "caller identity comes from the connection, ignoring forged body and proxy headers", %{
    conn: conn
  } do
    first =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.1")
      |> post("/api/gemini", %{url: "https://youtu.be/limits00001", caller_hash: "forged-a"})

    assert json_response(first, 202)["status"] == "processing"

    second =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.2")
      |> post("/api/gemini", %{
        url: "https://youtu.be/limits00002",
        caller_hash: "forged-b",
        submitter_username: "new name"
      })

    assert json_response(second, 429)["reason"] == "caller_rate_limited"
    assert [reservation] = Repo.all(Reservation)
    assert reservation.caller_hash == Caller.from_ip(conn.remote_ip)
    refute reservation.caller_hash in ["forged-a", "forged-b", "127.0.0.1"]
  end

  test "API and connected LiveView share the verified proxy caller bucket", %{conn: conn} do
    previous = Application.get_env(:drag_n_stamp, :trusted_proxy_cidrs)
    Application.put_env(:drag_n_stamp, :trusted_proxy_cidrs, ["127.0.0.1/32", "192.0.2.10/32"])
    on_exit(fn -> Application.put_env(:drag_n_stamp, :trusted_proxy_cidrs, previous) end)
    headers = "198.51.100.99, 203.0.113.19, 192.0.2.10"

    first =
      conn
      |> put_req_header("x-forwarded-for", headers)
      |> post("/api/gemini", %{url: "https://youtu.be/limits00001"})

    assert json_response(first, 202)["status"] == "processing"

    {:ok, view, _html} = conn |> put_req_header("x-forwarded-for", headers) |> live("/")

    html =
      view
      |> form("#url-form", %{url: "https://youtu.be/limits00002", username: "changed name"})
      |> render_submit()

    assert html =~ "Too many submissions from this connection"
    assert [first_reservation] = Repo.all(Reservation)
    assert first_reservation.caller_hash == Caller.from_ip({203, 0, 113, 19})

    second =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.20, 192.0.2.10")
      |> post("/api/gemini", %{url: "https://youtu.be/limits00003"})

    assert json_response(second, 202)["status"] == "processing"
    assert Repo.aggregate(Reservation, :count) == 2
  end

  test "a public LiveView event cannot post a comment even when called directly", %{conn: conn} do
    ts =
      %Timestamp{}
      |> Timestamp.changeset(%{
        url: "https://youtu.be/limits00001",
        channel_name: "test",
        content: "0:00 Intro",
        distilled_content: "0:00 Intro",
        processing_status: :ready
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "[phx-click=retry_comment]")

    assert render_click(view, "retry_comment", %{
             "id" => to_string(ts.id),
             "authority" => "operator"
           }) =~ "operator approval"

    assert Repo.get!(Timestamp, ts.id).youtube_comment_attempts == 0
    assert Repo.aggregate(DragNStamp.PublicationPolicy.Attempt, :count) == 0
  end

  test "IPv6 rotation inside the same /64 shares a caller bucket" do
    assert Caller.from_ip({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
             Caller.from_ip({0x2001, 0xDB8, 1, 2, 123, 456, 789, 999})

    refute Caller.from_ip({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
             Caller.from_ip({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})
  end
end
