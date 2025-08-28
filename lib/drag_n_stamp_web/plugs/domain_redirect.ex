defmodule DragNStampWeb.Plugs.DomainRedirect do
  @moduledoc """
  Redirects requests from Fly.io domains to the canonical domain stamp-bot.com
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "host") do
      [host] when host in ["drag-n-stamp-dev.fly.dev", "drag-n-stamp-prod.fly.dev"] ->
        redirect_url = "https://stamp-bot.com#{conn.request_path}#{query_string(conn)}"
        
        conn
        |> put_status(:moved_permanently)
        |> put_resp_header("location", redirect_url)
        |> halt()
      
      _ ->
        conn
    end
  end

  defp query_string(conn) do
    case conn.query_string do
      "" -> ""
      qs -> "?" <> qs
    end
  end
end