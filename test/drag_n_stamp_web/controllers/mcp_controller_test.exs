defmodule DragNStampWeb.McpControllerTest do
  use DragNStampWeb.ConnCase, async: false
  use Oban.Testing, repo: DragNStamp.Repo
  import Ecto.Query
  alias DragNStamp.{Repo, Submissions, Timestamp}
  alias DragNStamp.Plugin.Stats
  alias DragNStamp.Plugin.Usage.Event
  alias DragNStamp.Submissions.{Processor, PublishWorker, Worker}
  alias DragNStamp.Timestamps.GeminiClient.Result

  setup do
    previous =
      for key <- [:plugin, :work_budget, :publication_mode],
          into: %{},
          do: {key, Application.get_env(:drag_n_stamp, key)}

    Application.put_env(:drag_n_stamp, :plugin, enabled: true)
    Application.put_env(:drag_n_stamp, :work_budget, enabled: false)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:drag_n_stamp, key),
          else: Application.put_env(:drag_n_stamp, key, value)
      end
    end)

    :ok
  end

  test "initializes and exposes only the two declared tools without processing a video", %{
    conn: conn
  } do
    result =
      rpc(conn, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      })["result"]

    assert result["protocolVersion"] == "2025-11-25"
    assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert result["instructions"] =~ "saved publicly"
    tools = rpc(conn, "tools/list")["result"]["tools"]
    assert Enum.map(tools, & &1["name"]) == ["generate_chapters", "get_chapters"]
    assert hd(tools)["annotations"]["readOnlyHint"] == false
    assert List.last(tools)["annotations"]["readOnlyHint"] == true
    assert Enum.all?(tools, &(&1["outputSchema"]["required"] == ["status"]))
    assert Repo.aggregate(Timestamp, :count) == 0
    assert Repo.aggregate(Event, :count) == 0
  end

  test "notifications return 202 without starting a tool", %{conn: conn} do
    response = post_json(conn, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response.status == 202
    assert response.resp_body == ""

    response =
      post_json(conn, %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "generate_chapters", "arguments" => %{"url" => video(1)}}
      })

    assert response.status == 202
    assert Repo.aggregate(Timestamp, :count) == 0
  end

  test "rejects invalid origins, unsupported versions, and malformed requests", %{conn: conn} do
    for origin <- ["https://evil.example", "https://chatgpt.com.evil.example", "null"] do
      response =
        conn
        |> put_req_header("origin", origin)
        |> post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert json_response(response, 403)["error"]["message"] == "Origin not allowed"
    end

    response =
      conn
      |> put_req_header("mcp-protocol-version", "unsupported")
      |> post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert json_response(response, 400)["error"]["message"] =~ "Unsupported"

    for body <- [
          %{},
          %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"},
          [%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}],
          %{"jsonrpc" => "2.0", "id" => nil, "method" => "ping"}
        ] do
      assert json_response(post_json(conn, body), 400)["error"]["code"] == -32600
    end

    assert rpc(conn, "missing")["error"]["code"] == -32601
    assert rpc(conn, "tools/call", %{"name" => "post_comment"})["error"]["code"] == -32602
  end

  test "supports stateless clients and validates preflights", %{conn: conn} do
    assert response(conn, "GET", "/mcp").status == 405
    assert response(conn, "DELETE", "/mcp").status == 405
    preflight = conn |> put_req_header("origin", "https://chatgpt.com") |> options("/mcp")
    assert preflight.status == 204
    assert get_resp_header(preflight, "access-control-allow-origin") == ["https://chatgpt.com"]

    assert hd(get_resp_header(preflight, "access-control-allow-headers")) =~
             "mcp-protocol-version"

    assert (conn |> put_req_header("origin", "https://evil.example") |> options("/mcp")).status ==
             403

    initialized =
      rpc(conn, "initialize", %{
        "protocolVersion" => "future",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      })

    assert initialized["result"]["protocolVersion"] == "2025-11-25"
  end

  test "queues one durable job and reuses it across URL variants", %{conn: conn} do
    first = call(conn, "generate_chapters", %{"url" => video(1)}, "user-one", "chat-one")
    assert first["isError"] == false
    result = first["structuredContent"]
    assert result["status"] == "processing"
    assert result["result_url"] =~ "/submissions/"

    same =
      call(
        conn,
        "generate_chapters",
        %{"url" => "https://youtu.be/00000000001?t=30"},
        "user-two",
        "chat-two"
      )

    assert same["structuredContent"]["job_id"] == result["job_id"]
    assert Repo.aggregate(Timestamp, :count) == 1
    assert length(all_enqueued(worker: Worker)) == 1
    assert Repo.aggregate(from(e in Event, where: e.new_work), :count) == 1
    timestamp = Submissions.get(result["job_id"])
    assert timestamp.processing_context["disable_automatic_publication"] == true
    refute_enqueued(worker: PublishWorker)
  end

  test "returns cached chapters and deep links without spending a processing allowance", %{
    conn: conn
  } do
    timestamp = ready(1)
    Application.put_env(:drag_n_stamp, :plugin, daily_new_jobs: 1)

    result =
      call(conn, "generate_chapters", %{"url" => video(1)}, "subject", "chat")[
        "structuredContent"
      ]

    assert result["status"] == "ready"
    assert result["cached"] == true
    assert result["job_id"] == to_string(timestamp.id)
    assert result["chapter_text"] == "0:00 Intro\n1:30 Demo"
    assert List.last(result["chapters"])["url"] == video(1) <> "&t=90s"
    assert result["chapters"] |> Enum.map(& &1["start_seconds"]) == [0, 90]
    refute_enqueued(worker: Worker)
    assert Stats.snapshot().cached_generate_calls == 1
    assert Stats.snapshot().new_jobs == 0
  end

  test "get reads processing, ready, missing and failed results without restarting work", %{
    conn: conn
  } do
    {:ok, timestamp, _} = Submissions.submit(video(1))

    assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["structuredContent"][
             "status"
           ] == "processing"

    timestamp =
      Submissions.update!(timestamp, %{processing_status: :ready, content: "0:00 Intro"})

    assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["structuredContent"][
             "status"
           ] == "ready"

    Submissions.update!(timestamp, %{
      processing_status: :failed,
      processing_context: %{"public_error" => "Video unavailable"}
    })

    assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["isError"]

    assert call(conn, "get_chapters", %{"job_id" => "9223372036854775808"})["structuredContent"][
             "reason"
           ] == "not_found"

    assert length(all_enqueued(worker: Worker)) == 1
    assert Stats.snapshot().generate_calls == 0
    assert Stats.snapshot().status_checks == 4
  end

  test "normalizes legacy short links and refuses invalid saved chapter sets", %{conn: conn} do
    timestamp = ready(1, %{url: "https://youtu.be/00000000001?si=tracking"})

    result =
      call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["structuredContent"]

    assert result["video_url"] == video(1)
    assert List.last(result["chapters"])["url"] == video(1) <> "&t=90s"

    for content <- ["1:30 Later\n0:00 Earlier", "0:00 One\n0:00 Duplicate", "0:99 Invalid time"] do
      timestamp = Submissions.update!(timestamp, %{content: content})

      assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})[
               "structuredContent"
             ]["reason"] == "chapters_unavailable"
    end

    timestamp =
      Submissions.update!(timestamp, %{
        content: "0:00 Intro\n1:30 Beyond end",
        video_duration_seconds: 30
      })

    assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["isError"]
  end

  test "reports current completion and cost for distinct plugin-admitted jobs", %{conn: conn} do
    result =
      call(conn, "generate_chapters", %{"url" => video(1)}, "subject", "one")["structuredContent"]

    timestamp = Submissions.get(result["job_id"])

    Submissions.update!(timestamp, %{
      processing_status: :ready,
      content: "0:00 Intro",
      estimated_cost_usd: Decimal.new("0.125"),
      processing_context: Map.put(timestamp.processing_context, "cost_complete", true)
    })

    call(conn, "generate_chapters", %{"url" => video(1)}, "subject", "two")
    stats = Stats.snapshot()
    assert stats.new_jobs == 1
    assert stats.current_generated_results == [%{status: :ready, count: 1}]
    assert stats.results_with_incomplete_cost == 0

    assert Decimal.equal?(
             Decimal.new(stats.current_generated_result_cost_usd),
             Decimal.new("0.125")
           )
  end

  test "rejects invalid arguments and sentinel results with useful tool errors", %{conn: conn} do
    for args <- [
          %{},
          %{"url" => "https://youtube.com.evil.example/watch?v=00000000001"},
          %{"url" => video(1), "publish" => true},
          %{"url" => 123},
          %{"url" => String.duplicate("x", 2049)},
          []
        ] do
      assert call(conn, "generate_chapters", args)["isError"]
    end

    for id <- ["0", "-1", "1abc", 1] do
      assert call(conn, "get_chapters", %{"job_id" => id})["isError"]
    end

    timestamp = ready(1, %{content: "UNWATCHED"})

    assert call(conn, "get_chapters", %{"job_id" => to_string(timestamp.id)})["structuredContent"][
             "reason"
           ] == "chapters_unavailable"

    refute_enqueued(worker: Worker)
  end

  test "daily admission cap is shared across subjects but cached results and reads still work", %{
    conn: conn
  } do
    Application.put_env(:drag_n_stamp, :plugin, daily_new_jobs: 1)
    accepted = call(conn, "generate_chapters", %{"url" => video(1)}, "one", "one")
    assert accepted["structuredContent"]["status"] == "processing"
    denied = call(conn, "generate_chapters", %{"url" => video(2)}, "two", "two")
    assert denied["structuredContent"]["reason"] == "plugin_daily_limit"
    ready(3)

    assert call(conn, "generate_chapters", %{"url" => video(3)}, "two", "two")[
             "structuredContent"
           ]["status"] == "ready"

    assert call(conn, "get_chapters", %{"job_id" => accepted["structuredContent"]["job_id"]})[
             "structuredContent"
           ]["status"] == "processing"

    assert Stats.snapshot().new_jobs == 1
    assert Repo.aggregate(Timestamp, :count) == 2
  end

  test "subjects on one transport have separate allowances bounded by the transport cap", %{
    conn: conn
  } do
    Application.put_env(:drag_n_stamp, :plugin,
      actor_daily_new_jobs: 1,
      transport_hourly_new_jobs: 2
    )

    assert call(conn, "generate_chapters", %{"url" => video(1)}, "one", "one")[
             "structuredContent"
           ]["status"] == "processing"

    assert call(conn, "generate_chapters", %{"url" => video(2)}, "one", "two")[
             "structuredContent"
           ]["reason"] == "plugin_actor_limit"

    assert call(conn, "generate_chapters", %{"url" => video(2)}, "two", "two")[
             "structuredContent"
           ]["status"] == "processing"

    assert call(conn, "generate_chapters", %{"url" => video(3)}, "three", "three")[
             "structuredContent"
           ]["reason"] == "plugin_transport_limit"

    assert Stats.snapshot().new_jobs == 2
  end

  test "budget failure rolls back plugin admission, submission and job together", %{conn: conn} do
    Application.put_env(:drag_n_stamp, :work_budget, enabled: true, total_budget_microusd: 1)
    result = call(conn, "generate_chapters", %{"url" => video(1)}, "one", "one")
    assert result["structuredContent"]["reason"] == "total_budget_exceeded"
    assert Repo.aggregate(Timestamp, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Stats.snapshot().new_jobs == 0
    assert Repo.aggregate(Event, :count) == 1
  end

  test "plugin generation never auto-posts, even when deployment auto-publication is enabled", %{
    conn: conn
  } do
    Application.put_env(:drag_n_stamp, :publication_mode, :automatic)
    result = call(conn, "generate_chapters", %{"url" => video(1)})["structuredContent"]

    timestamp =
      Submissions.get(result["job_id"])
      |> Submissions.update!(%{content: "0:00 Intro", video_duration_seconds: 30})

    assert {:ok, finished} =
             Processor.process(timestamp,
               api_key: "fixture-key",
               text_fun: fn _, _, _ ->
                 {:ok,
                  %Result{
                    content: "0:00 Intro",
                    timestamps: [%{seconds: 0, title: "Intro"}],
                    model: "fixture",
                    attempts: 1,
                    duration_ms: 0
                  }}
               end
             )

    assert finished.processing_status == :ready
    refute_enqueued(worker: PublishWorker)
  end

  test "usage hashes optional hints and separates generation demand from status polling", %{
    conn: conn
  } do
    timestamp = ready(1, %{estimated_cost_usd: Decimal.new("1.25")})

    call(
      conn,
      "generate_chapters",
      %{"url" => video(1)},
      "private-subject",
      "private-session-one"
    )

    call(
      conn,
      "generate_chapters",
      %{"url" => video(1)},
      "private-subject",
      "private-session-two"
    )

    for _ <- 1..3,
        do:
          call(
            conn,
            "get_chapters",
            %{"job_id" => to_string(timestamp.id)},
            "private-subject",
            "private-session-two"
          )

    call(conn, "generate_chapters", %{"url" => video(1)})
    events = Repo.all(Event)
    assert Enum.all?(events, &(byte_size(&1.actor_hash) == 64))
    refute inspect(events) =~ "private-subject"
    refute inspect(events) =~ "private-session"
    stats = Stats.snapshot()
    assert stats.requesting_subjects == 1
    assert stats.returning_subjects == 1
    assert stats.accepted_calls_without_subject == 1
    assert stats.generate_calls == 3
    assert stats.status_checks == 3
    assert stats.new_jobs == 0
    assert stats.current_generated_result_cost_usd == nil
  end

  test "kill switch stops calls before mutation and public support pages render", %{conn: conn} do
    Application.put_env(:drag_n_stamp, :plugin, enabled: false)

    response =
      post_json(conn, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "generate_chapters", "arguments" => %{"url" => video(1)}}
      })

    assert json_response(response, 503)["error"]["message"] =~ "temporarily unavailable"
    assert Repo.aggregate(Timestamp, :count) == 0

    for path <- ["/plugin", "/plugin/privacy", "/plugin/support"] do
      assert html_response(get(conn, path), 200) =~ "StampBot"
    end

    privacy = html_response(get(conn, "/plugin/privacy"), 200)
    assert privacy =~ "Saved public results"
    assert length(Regex.scan(~r/<html\b/, privacy)) == 1
    assert privacy =~ "<title>StampBot plugin privacy</title>"
  end

  defp rpc(conn, method, params \\ %{}),
    do:
      conn
      |> post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
      |> json_response(200)

  defp call(conn, name, args, subject \\ nil, session \\ nil) do
    meta = %{"openai/subject" => subject, "openai/session" => session}
    rpc(conn, "tools/call", %{"name" => name, "arguments" => args, "_meta" => meta})["result"]
  end

  defp post_json(conn, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(body))

  defp response(conn, "GET", path), do: get(conn, path)
  defp response(conn, "DELETE", path), do: delete(conn, path)

  defp video(id),
    do: "https://www.youtube.com/watch?v=" <> String.pad_leading(to_string(id), 11, "0")

  defp ready(id, attrs \\ %{}) do
    %Timestamp{}
    |> Timestamp.changeset(
      Map.merge(
        %{
          url: video(id),
          video_id: String.pad_leading(to_string(id), 11, "0"),
          channel_name: "Fixture",
          video_title: "Fixture video",
          processing_status: :ready,
          content: "0:00 Intro\n1:30 Demo"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
