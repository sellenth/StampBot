defmodule DragNStampWeb.HomeLiveTest do
  use DragNStampWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  use Oban.Testing, repo: DragNStamp.Repo

  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.Timestamps.SubmissionLimit
  alias DragNStamp.Submissions.Worker

  test "home page renders submit and feed in order", %{conn: conn} do
    insert_timestamp(%{
      submitter_username: "alice",
      channel_name: "Alpha Channel",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready,
      estimated_cost_usd: Decimal.new("0.012345")
    })

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#url-form")
    assert has_element?(view, "#feed")
    refute has_element?(view, "#leaderboard")
    assert html =~ "Est. cost: $0.0123"

    assert html_index(html, ~s(id="url-form")) < html_index(html, ~s(id="feed"))
  end

  test "partial request costs are labeled as a known subtotal", %{conn: conn} do
    insert_timestamp(%{
      estimated_cost_usd: Decimal.new("0.0123"),
      processing_context: %{"cost_complete" => false, "unknown_cost_requests" => 2}
    })

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Known cost: $0.0123"
    assert html =~ "2 provider requests have unknown cost"
  end

  test "valid submission is durably queued and survives reopening the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#url-form", %{
        url: "https://www.youtube.com/watch?v=abc123xyz89",
        username: "alice"
      })
      |> render_submit()

    assert html =~ "Submission saved. You can leave this page while it processes."
    timestamp = Repo.get_by!(Timestamp, url: "https://www.youtube.com/watch?v=abc123xyz89")
    assert timestamp.processing_status == :processing
    assert timestamp.submitter_username == "alice"
    assert_enqueued(worker: Worker, args: %{timestamp_id: timestamp.id})
    refute has_element?(view, "#url-form button[type=submit][disabled]")

    {:ok, reopened, reopened_html} = live(conn, ~p"/")
    assert reopened_html =~ "Submission saved. Waiting to process."
    assert has_element?(reopened, "#time-#{timestamp.id}")
    assert has_element?(view, "#feed")
    refute has_element?(view, "#leaderboard")
  end

  test "duplicate submission and PubSub updates keep a single feed card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for url <- [
          "https://youtu.be/abc123xyz89",
          "https://www.youtube.com/watch?v=abc123xyz89&t=30"
        ] do
      view
      |> form("#url-form", %{url: url, username: "alice"})
      |> render_submit()
    end

    timestamp = Repo.get_by!(Timestamp, url: "https://www.youtube.com/watch?v=abc123xyz89")
    assert length(all_enqueued(worker: Worker)) == 1

    assert render(view)
           |> Floki.parse_fragment!()
           |> Floki.find("#time-#{timestamp.id}")
           |> length() == 1

    updated =
      timestamp
      |> Timestamp.changeset(%{
        processing_status: :ready,
        content: "0:00 Intro",
        distilled_content: "0:00 Intro"
      })
      |> Repo.update!()

    send(view.pid, {:timestamp_updated, updated})
    assert has_element?(view, "#timestamps-#{timestamp.id}", "0:00 Intro")
  end

  test "invalid video URLs are rejected before creating a submission", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#url-form", %{
        url: "https://youtube.com.example.org/watch?v=abc123xyz89",
        username: "alice"
      })
      |> render_submit()

    assert html =~ "Please enter a valid YouTube video URL."
    assert Repo.aggregate(Timestamp, :count, :id) == 0
    refute_enqueued(worker: Worker)
  end

  test "manual retry queues work and atomically consumes the one-time retry", %{conn: conn} do
    timestamp =
      insert_timestamp(%{content: "0:00 UNWATCHED", distilled_content: "0:00 UNWATCHED"})

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "retry_submission", %{"id" => to_string(timestamp.id)})

    assert html =~ "Retry saved. You can leave this page while it processes."
    updated = Repo.get!(Timestamp, timestamp.id)
    assert updated.processing_status == :processing
    assert updated.processing_context["manual_retry_used"]
    assert_enqueued(worker: Worker, args: %{timestamp_id: timestamp.id})

    assert render_click(view, "retry_submission", %{"id" => to_string(timestamp.id)}) =~
             "Retry not allowed"

    assert length(all_enqueued(worker: Worker)) == 1
  end

  test "shows the funding banner and disables submissions at 1,000 timestamps", %{conn: conn} do
    insert_timestamps(SubmissionLimit.limit())

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#submission-limit-banner")
    assert html =~ SubmissionLimit.message()
    assert has_element?(view, "#url-form input[name=url][disabled]")
    assert has_element?(view, "#url-form input[name=username][disabled]")
    assert has_element?(view, "#url-form button[type=submit][disabled]", "Submissions Closed")

    assert Repo.aggregate(Timestamp, :count, :id) == SubmissionLimit.limit()
  end

  test "failed cards show the stored public reason instead of promising a retry", %{conn: conn} do
    insert_timestamp(%{
      processing_status: :failed,
      content: nil,
      distilled_content: nil,
      processing_error:
        "[captions_fallback_failed] YouTube temporarily rate-limited caption requests. (length=59m)"
    })

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "[data-failure-category=caption_pipeline]")
    assert html =~ "YouTube temporarily rate-limited caption requests. (length=59m)"
    assert html =~ "not scheduled an automatic retry"
    refute html =~ "Oops, something's not quite right here"
    refute html =~ "We will retry this submission"
  end

  defp insert_timestamp(attrs) do
    defaults = %{
      url: "https://www.youtube.com/watch?v=#{System.unique_integer([:positive])}",
      channel_name: "Channel",
      submitter_username: "anonymous",
      content: "0:00 Intro",
      distilled_content: "0:00 Intro",
      processing_status: :ready,
      youtube_comment_status: :not_attempted
    }

    %Timestamp{}
    |> Timestamp.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_timestamps(count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for index <- 1..count do
        %{
          url: "https://www.youtube.com/watch?v=homeLimit#{index}",
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

  defp html_index(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> raise "expected to find #{inspect(needle)} in rendered HTML"
    end
  end
end
