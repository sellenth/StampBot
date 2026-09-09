defmodule DragNStampWeb.ApiController do
  use DragNStampWeb, :controller

  alias DragNStamp.Submissions
  alias DragNStamp.Timestamps.SubmissionLimit

  def gemini(conn, params) do
    case Submissions.submit(Map.get(params, "url"), params) do
      {:ok, timestamp, disposition} ->
        payload = Submissions.response(timestamp)
        cached = timestamp.processing_status == :ready and disposition == :existing

        conn
        |> put_status(if(timestamp.processing_status == :ready, do: :ok, else: :accepted))
        |> put_resp_header("location", payload.status_url)
        |> put_resp_header("cache-control", "no-store")
        |> json(Map.put(payload, :cached, cached))

      {:error, :invalid_url} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          status: "error",
          reason: "invalid_url",
          message: "Enter a valid YouTube video URL."
        })

      {:error, :submission_limit_reached} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "error",
          reason: "submission_limit_reached",
          message: SubmissionLimit.message(),
          limit: SubmissionLimit.limit()
        })

      {:error, :retry_in_flight} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          status: "error",
          reason: "retry_in_flight",
          message: "The previous attempt is finishing. Please retry shortly."
        })

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "Could not save this submission. Please try again."})
    end
  end

  def submission(conn, %{"id" => id}) do
    case Submissions.get(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", message: "Submission not found."})

      timestamp ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(Submissions.response(timestamp))
    end
  end

  # Retained for clients that only record a link, without requesting generation.
  def receive_url(conn, %{"url" => url} = params) when is_binary(url) do
    username =
      case params["username"] do
        name when is_binary(name) ->
          if(String.trim(name) == "", do: "anonymous", else: String.trim(name))

        _ ->
          "anonymous"
      end

    json(conn, %{
      status: "success",
      message: "URL received",
      url: url,
      username: username,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  def receive_url(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "URL parameter is required"})
  end
end
