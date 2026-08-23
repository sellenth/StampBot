defmodule DragNStampWeb.HomeLive do
  use DragNStampWeb, :live_view
  alias DragNStamp.{Repo, Timestamp}
  alias DragNStamp.SEO.PagePath
  alias DragNStamp.Timestamps.{FailureMessage, SubmissionLimit}
  import Ecto.Query
  require Logger

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
    case Repo.get(Timestamp, id) do
      nil ->
        {:noreply, socket}

      %Timestamp{} = ts ->
        if retry_allowed?(ts) do
          now = DateTime.utc_now()
          ctx = ts.processing_context || %{}

          updated_ctx =
            ctx
            |> Map.put("manual_retry_used", true)
            |> Map.put("manual_retry_last_at", now)

          changes = %{processing_context: updated_ctx}

          {:ok, persisted} = Repo.update(Timestamp.changeset(ts, changes))

          Task.start(fn -> DragNStampWeb.ApiController.reprocess_timestamp(persisted) end)

          optimistic = %{
            persisted
            | processing_status: :processing,
              processing_error: nil
          }

          updated_list =
            Enum.map(socket.assigns.timestamps, fn t ->
              if t.id == optimistic.id, do: optimistic, else: t
            end)

          {:noreply,
           socket
           |> assign(:timestamps, updated_list)
           |> put_flash(:info, "Retry started for this submission.")}
        else
          {:noreply, put_flash(socket, :error, "Retry not allowed for this submission.")}
        end
    end
  end

  defp handle_submission(url, username, socket) do
    case validate_youtube_url(url) do
      :ok ->
        submitter_username =
          if username && String.trim(username) != "", do: String.trim(username), else: "anonymous"

        parent = self()

        Task.start(fn ->
          send(parent, {:generation_finished, generate_timestamps(url, submitter_username)})
        end)

        {:noreply,
         socket
         |> assign(:loading, true)
         |> put_flash(:info, "Generating timestamps... This may take a few minutes.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_info({:generation_finished, :ok}, socket) do
    {:noreply, assign(socket, :loading, false)}
  end

  def handle_info({:generation_finished, {:error, message}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> put_flash(:error, message)}
  end

  def handle_info({:timestamp_created, timestamp}, socket) do
    Logger.info("Received new timestamp via PubSub: #{timestamp.id}")

    updated_timestamps = [timestamp | socket.assigns.timestamps]

    {:noreply,
     socket
     |> assign(:timestamps, sort_timestamps(updated_timestamps, socket.assigns.sort_by))
     |> assign(:submission_limit_reached, length(updated_timestamps) >= SubmissionLimit.limit())
     |> put_flash(:info, "New timestamp received from #{timestamp.submitter_username}!")}
  end

  def handle_info({:timestamp_updated, timestamp}, socket) do
    timestamps = socket.assigns.timestamps

    updated_list =
      if Enum.any?(timestamps, &(&1.id == timestamp.id)) do
        Enum.map(timestamps, fn t -> if t.id == timestamp.id, do: timestamp, else: t end)
      else
        [timestamp | timestamps]
      end

    {:noreply, assign(socket, :timestamps, sort_timestamps(updated_list, socket.assigns.sort_by))}
  end

  defp validate_youtube_url(url) do
    cond do
      url == "" ->
        {:error, "Please enter a YouTube URL"}

      not (String.contains?(url, "youtube.com") or
             String.contains?(url, "youtu.be") or
               String.contains?(url, "m.youtube.com")) ->
        {:error, "Please enter a valid YouTube URL"}

      true ->
        :ok
    end
  end

  defp generate_timestamps(url, submitter_username) do
    base_url = DragNStampWeb.Endpoint.url()
    api_endpoint = "#{base_url}/api/gemini"

    headers = [{"Content-Type", "application/json"}]

    body =
      Jason.encode!(%{
        url: url,
        channel_name: "anonymous",
        submitter_username: submitter_username
      })

    case Finch.build(:post, api_endpoint, headers, body)
         |> Finch.request(DragNStamp.Finch, receive_timeout: 300_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Timestamp generation completed successfully: #{status}")
        :ok

      {:ok, response} ->
        Logger.info("Timestamp generation completed: #{inspect(response.status)}")

        message =
          case Jason.decode(response.body) do
            {:ok, %{"message" => message}} when is_binary(message) -> message
            _ -> "StampBot could not process that video right now."
          end

        {:error, message}

      {:error, reason} ->
        Logger.error("Failed to generate timestamps: #{inspect(reason)}")
        {:error, "StampBot could not process that video right now."}
    end
  end

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
    "javascript:(function(){function showCustomAlert(title,message,type){var isDark=window.matchMedia('(prefers-color-scheme: dark)').matches;console.log('Browser theme detected - Dark mode:',isDark);var bgColor=isDark?'#1a1a1a':'white';var textColor=isDark?'#fff':'#111827';var borderColor=isDark?'#404040':'#e5e7eb';var contentColor=isDark?'#ccc':'#374151';var btnBg=isDark?'#fff':'#3b82f6';var btnColor=isDark?'#000':'white';console.log('Modal colors - bg:',bgColor,'text:',textColor);var overlay=document.createElement('div');overlay.style.cssText='position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);z-index:999999;display:flex;align-items:center;justify-content:center;font-family:system-ui,-apple-system,sans-serif';var modal=document.createElement('div');modal.style.cssText='background:'+bgColor+';padding:24px;border-radius:12px;box-shadow:0 25px 50px rgba(0,0,0,0.25);max-width:500px;width:90%;max-height:80vh;overflow-y:auto';var header=document.createElement('div');header.style.cssText='display:flex;align-items:center;gap:12px;margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid '+borderColor;var icon=document.createElement('div');icon.style.cssText='width:24px;height:24px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:bold;color:white';if(type==='success'){icon.style.background='#10b981';icon.textContent='✓'}else if(type==='error'){icon.style.background='#ef4444';icon.textContent='✕'}else{icon.style.background='#3b82f6';icon.textContent='i'}var titleEl=document.createElement('h3');titleEl.style.cssText='margin:0;font-size:18px;font-weight:600;color:'+textColor;titleEl.textContent=title;header.appendChild(icon);header.appendChild(titleEl);var content=document.createElement('div');content.style.cssText='color:'+contentColor+';line-height:1.5;margin-bottom:20px;white-space:pre-wrap';content.textContent=message;var button=document.createElement('button');button.style.cssText='background:'+btnBg+';color:'+btnColor+';border:none;padding:10px 20px;border-radius:6px;font-size:14px;font-weight:500;cursor:pointer;float:right';button.textContent='OK';button.onclick=function(){overlay.remove()};modal.appendChild(header);modal.appendChild(content);modal.appendChild(button);overlay.appendChild(modal);document.body.appendChild(overlay);overlay.onclick=function(e){if(e.target===overlay)overlay.remove()}}var e='#{api_endpoint}',u=window.location.href,y=u.indexOf('youtube.com')>-1||u.indexOf('youtu.be')>-1||u.indexOf('m.youtube.com')>-1;if(!y){showCustomAlert('YouTube Required','This bookmarklet only works on YouTube videos!','error');return;}showCustomAlert('Processing...','Analyzing video and generating timestamps. This may take a few minutes.','info');var channelName='anonymous';try{console.log('Attempting to extract channel name...');var channelSelectors=['#channel-name a','#text a','.ytd-channel-name a','[class*=\"channel\"] a','.owner-text a','.ytd-video-owner-renderer a'];for(var i=0;i<channelSelectors.length;i++){var chEl=document.querySelector(channelSelectors[i]);if(chEl&&chEl.textContent){channelName=chEl.textContent.trim();console.log('Channel name found with selector',channelSelectors[i],':',channelName);break;}}console.log('Final channel name:',channelName);}catch(x){console.log('Error extracting channel info:',x);}fetch(e,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({channel_name:channelName,url:u})}).then(async function(r){var data={};try{data=await r.json()}catch(_){}if(!r.ok){var msg=(data&&data.message)||'Unable to process this video.';showCustomAlert('Cannot Process',msg,'error');throw new Error(msg);}return data;}).then(function(d){var message='Video: '+u+'\\nChannel: '+channelName+'\\n\\nTimestamps:\\n'+d.response;showCustomAlert('Timestamps Generated!',message,'success');console.log('Gemini Response:',d);}).catch(function(er){console.error('Error:',er);});})();"
  end
end
