defmodule DragNStampWeb.HomeLive do
  use DragNStampWeb, :live_view
  alias DragNStamp.{Repo, Submissions, Timestamp}
  alias DragNStamp.SEO.PagePath
  alias DragNStamp.Timestamps.{FailureMessage, SubmissionLimit}
  import Ecto.Query
  require Logger

  @submission_client_path Path.expand("../../../priv/static/js/submission-client.js", __DIR__)
  @bookmarklet_path Path.expand("../../../priv/static/js/bookmarklet.js", __DIR__)
  @external_resource @submission_client_path
  @external_resource @bookmarklet_path
  @submission_client_source File.read!(@submission_client_path)
  @bookmarklet_source File.read!(@bookmarklet_path)

  @topic "timestamps"
  @per_page 10
  @status_failure_window_minutes 240
  @status_processing_window_minutes 90

  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DragNStamp.PubSub, @topic)
    end

    base_url = DragNStampWeb.Endpoint.url()
    api_endpoint = "#{base_url}/api/gemini"
    bookmarklet_code = build_bookmarklet_code(api_endpoint)
    is_extension_mode = params["mode"] == "extension"
    page = parse_page(params["page"])
    timestamps = load_timestamps()
    submission_limit_reached = length(timestamps) >= SubmissionLimit.limit()

    {:ok,
     assign(socket,
       bookmarklet_code: bookmarklet_code,
       loading: false,
       submission_limit_reached: submission_limit_reached,
       submission_limit_message: SubmissionLimit.message(),
       extension_mode: is_extension_mode,
       timestamps: timestamps,
       filter_submitter: "",
       filter_channel: "",
       sort_by: "newest",
       page: page,
       per_page: @per_page,
       page_title: "StampBot - YouTube Timestamp Generator and Feed",
       page_description:
         "Generate precise YouTube video timestamps automatically using AI and browse the latest community submissions in one place."
     )}
  end

  def handle_event("generate_from_url", %{"url" => url, "username" => username}, socket) do
    cond do
      socket.assigns.submission_limit_reached or SubmissionLimit.reached?() ->
        {:noreply,
         socket
         |> assign(:submission_limit_reached, true)
         |> put_flash(:error, SubmissionLimit.message())}

      true ->
        handle_submission(url, username, socket)
    end
  end

  def handle_event("filter_changed", params, socket) do
    {:noreply,
     assign(socket,
       filter_submitter: params["submitter"] || "",
       filter_channel: params["channel"] || "",
       sort_by: params["sort"] || "newest",
       page: 1
     )}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, assign(socket, page: String.to_integer(page))}
  end

  def handle_event("retry_comment", %{"id" => id}, socket) do
    case Repo.get(Timestamp, id) do
      nil ->
        {:noreply, socket}

      ts ->
        if ts.youtube_comment_status == :succeeded || not is_nil(ts.youtube_comment_external_id) do
          {:noreply, socket}
        else
          result = DragNStamp.Commenter.post_for_timestamp(ts)

          updated_ts =
            case result do
              {:ok, updated, _info} -> updated
              _ -> ts
            end

          updated_list =
            Enum.map(socket.assigns.timestamps, fn t ->
              if t.id == updated_ts.id, do: updated_ts, else: t
            end)

          {:noreply, assign(socket, :timestamps, updated_list)}
        end
    end
  end

  def handle_event("retry_submission", %{"id" => id}, socket) do
    case Submissions.get(id) do
      %Timestamp{} = timestamp ->
        if retry_allowed?(timestamp) do
          case Submissions.retry(timestamp) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> put_timestamp(updated)
               |> put_flash(:info, "Retry saved. You can leave this page while it processes.")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, submission_error(reason))}
          end
        else
          {:noreply, put_flash(socket, :error, "Retry not allowed for this submission.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "This submission could not be found.")}
    end
  end

  defp handle_submission(url, username, socket) do
    attrs = %{channel_name: "anonymous", submitter_username: username}

    case Submissions.submit(url, attrs) do
      {:ok, timestamp, _disposition} ->
        message =
          case timestamp.processing_status do
            :ready -> "Timestamps are already available in the feed."
            :failed -> "This submission could not be processed. See its details in the feed."
            :processing -> "Submission saved. You can leave this page while it processes."
          end

        {:noreply,
         socket
         |> put_timestamp(timestamp)
         |> assign(:loading, false)
         |> put_flash(:info, message)}

      {:error, :submission_limit_reached} ->
        {:noreply,
         socket
         |> assign(:submission_limit_reached, true)
         |> put_flash(:error, SubmissionLimit.message())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, submission_error(reason))}
    end
  end

  def handle_info({:timestamp_created, timestamp}, socket) do
    {:noreply, put_timestamp(socket, timestamp)}
  end

  def handle_info({:timestamp_updated, timestamp}, socket) do
    {:noreply, put_timestamp(socket, timestamp)}
  end

  defp put_timestamp(socket, timestamp) do
    timestamps = socket.assigns.timestamps

    updated =
      if Enum.any?(timestamps, &(&1.id == timestamp.id)) do
        Enum.map(timestamps, fn existing ->
          if existing.id == timestamp.id, do: timestamp, else: existing
        end)
      else
        [timestamp | timestamps]
      end

    socket
    |> assign(:timestamps, sort_timestamps(updated, socket.assigns.sort_by))
    |> assign(:submission_limit_reached, length(updated) >= SubmissionLimit.limit())
  end

  defp submission_error(:invalid_url), do: "Please enter a valid YouTube video URL."
  defp submission_error(:not_found), do: "This submission could not be found."

  defp submission_error(:retry_in_flight),
    do: "The previous attempt is finishing. Please try again in a moment."

  defp submission_error(:retry_not_allowed), do: "Retry not allowed for this submission."
  defp submission_error(:submission_limit_reached), do: SubmissionLimit.message()
  defp submission_error(_), do: "StampBot could not save this submission. Please try again."

  defp load_timestamps do
    Timestamp
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page_number, ""} when page_number > 0 -> page_number
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp sort_timestamps(timestamps, sort_by) do
    case sort_by do
      "newest" -> Enum.sort_by(timestamps, & &1.inserted_at, {:desc, NaiveDateTime})
      "oldest" -> Enum.sort_by(timestamps, & &1.inserted_at, {:asc, NaiveDateTime})
      _ -> timestamps
    end
  end

  defp filtered_timestamps(assigns) do
    assigns.timestamps
    |> Enum.filter(fn t ->
      (assigns.filter_submitter == "" or t.submitter_username == assigns.filter_submitter) and
        (assigns.filter_channel == "" or t.channel_name == assigns.filter_channel)
    end)
    |> sort_timestamps(assigns.sort_by)
  end

  defp unique_submitters(timestamps) do
    timestamps
    |> Enum.map(& &1.submitter_username)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unique_channels(timestamps) do
    timestamps
    |> Enum.map(& &1.channel_name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp paginated_timestamps(assigns) do
    filtered = filtered_timestamps(assigns)
    offset = (assigns.page - 1) * assigns.per_page

    filtered
    |> Enum.slice(offset, assigns.per_page)
  end

  defp total_pages(assigns) do
    total = length(filtered_timestamps(assigns))
    div(total + assigns.per_page - 1, assigns.per_page)
  end

  defp seo_page_path(%Timestamp{id: nil}), do: nil

  defp seo_page_path(%Timestamp{} = timestamp) do
    PagePath.page_path(timestamp)
  end

  defp overall_status(assigns) do
    timestamps = assigns.timestamps

    case latest_recent_failure(timestamps) do
      nil ->
        case recent_processing_count(timestamps) do
          0 -> :healthy
          count -> {:processing, count}
        end

      failure ->
        {:issue, failure}
    end
  end

  defp latest_recent_failure(timestamps) do
    timestamps
    |> Enum.filter(&recent_failure?/1)
    |> Enum.sort_by(&reference_time/1, {:desc, NaiveDateTime})
    |> List.first()
  end

  defp recent_failure?(%Timestamp{} = timestamp) do
    timestamp.processing_status == :failed and
      not unsupported_failure?(timestamp) and
      recent?(reference_time(timestamp), @status_failure_window_minutes)
  end

  defp unsupported_failure?(%Timestamp{processing_error: msg}) when is_binary(msg) do
    String.starts_with?(msg, "[unsupported:")
  end

  defp unsupported_failure?(_), do: false

  defp recent_processing_count(timestamps) do
    timestamps
    |> Enum.filter(fn t ->
      t.processing_status == :processing and
        recent?(reference_time(t), @status_processing_window_minutes)
    end)
    |> length()
  end

  defp reference_time(%Timestamp{} = timestamp) do
    timestamp.updated_at || timestamp.inserted_at
  end

  defp has_distilled_content?(%Timestamp{distilled_content: content}) when is_binary(content) do
    String.trim(content) != ""
  end

  defp has_distilled_content?(_), do: false

  defp content_contains_unwatched?(%Timestamp{content: content}) when is_binary(content) do
    String.contains?(content, "0:00 UNWATCHED")
  end

  defp content_contains_unwatched?(_), do: false

  defp manual_retry_used?(%Timestamp{processing_context: ctx}) when is_map(ctx) do
    case ctx do
      %{} = m ->
        Map.get(m, "manual_retry_used") == true or
          Map.get(m, "manual_retry_count", 0) |> Kernel.>=(1)

      _ ->
        false
    end
  end

  defp manual_retry_used?(_), do: false

  defp retry_allowed?(%Timestamp{} = ts) do
    content_contains_unwatched?(ts) and not manual_retry_used?(ts)
  end

  defp processing_message(%Timestamp{processing_phase: phase}) do
    case phase do
      "queued" -> "Submission saved. Waiting to process."
      "acquiring" -> "Reading the video to prepare timestamps."
      "generating" -> "Generating timestamps from the video."
      "distilling" -> "Finishing the timestamp list."
      "retrying" -> "Processing hit a temporary problem. A retry is scheduled."
      _ -> "Processing timestamps. You can return to this page for updates."
    end
  end

  defp failure_details(%Timestamp{} = timestamp), do: FailureMessage.for_timestamp(timestamp)

  defp recent?(nil, _window_minutes), do: false

  defp recent?(%NaiveDateTime{} = dt, window_minutes) when is_integer(window_minutes) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :minute) <= window_minutes
  end

  defp recent?(%DateTime{} = dt, window_minutes) when is_integer(window_minutes) do
    recent?(DateTime.to_naive(dt), window_minutes)
  end

  defp recent?(_, _), do: false

  defp format_inserted_at(%Timestamp{} = timestamp) do
    format_datetime(timestamp.inserted_at)
  end

  defp format_estimated_cost(%Timestamp{
         estimated_cost_usd: nil,
         processing_status: :processing
       }),
       do: "Calculating…"

  defp format_estimated_cost(%Timestamp{estimated_cost_usd: nil}), do: "Unavailable"

  defp format_estimated_cost(%Timestamp{estimated_cost_usd: %Decimal{} = cost}) do
    threshold = Decimal.new("0.0001")

    if Decimal.positive?(cost) and Decimal.lt?(cost, threshold) do
      "<$0.0001"
    else
      "$" <> (cost |> Decimal.round(4) |> Decimal.to_string(:normal))
    end
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt), do: format_datetime(DateTime.to_naive(dt))

  defp format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%b %d, %Y %I:%M %p UTC")
  rescue
    _ -> NaiveDateTime.to_string(ndt)
  end

  defp format_datetime(other), do: to_string(other)

  defp iso_string(nil), do: nil

  defp iso_string(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"

  defp iso_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso_string(other), do: to_string(other)

  defp status_reference_time(%Timestamp{} = timestamp), do: reference_time(timestamp)

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural

  defp build_bookmarklet_code(api_endpoint) do
    source =
      "(function(apiEndpoint){\n" <>
        @submission_client_source <>
        "\n" <> @bookmarklet_source <> "\n})(" <> Jason.encode!(api_endpoint) <> ")"

    "javascript:" <> URI.encode(source, &URI.char_unreserved?/1)
  end
end
