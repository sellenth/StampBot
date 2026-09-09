defmodule DragNStampWeb.OperatorController do
  use DragNStampWeb, :controller
  alias DragNStamp.{Submissions, PublicationPolicy}

  def publish(conn, %{"id" => id}) do
    with true <- conn.assigns[:operator_authenticated] == true,
         timestamp when not is_nil(timestamp) <- Submissions.get(id),
         {:ok, job} <- PublicationPolicy.enqueue(timestamp, :operator) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:accepted)
      |> json(%{status: "accepted", submission_id: timestamp.id, job_id: job.id})
    else
      nil ->
        error(conn, :not_found, "Submission not found.")

      false ->
        error(conn, :unauthorized, "Operator authentication required.")

      {:error, :not_found} ->
        error(conn, :not_found, "Submission not found.")

      {:error, :publication_not_authorized} ->
        error(conn, :forbidden, "Publication is disabled.")

      {:error, _reason} ->
        error(
          conn,
          :conflict,
          "This submission cannot be queued for publication in its current state."
        )
    end
  end

  defp error(conn, status, message),
    do: conn |> put_status(status) |> json(%{status: "error", message: message})
end
