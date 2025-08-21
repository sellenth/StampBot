defmodule DragNStampWeb.Plugs.CORS do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check if this is an extension request
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""

    is_extension =
      String.contains?(conn.request_path, "extension") or
        String.contains?(user_agent, "Chrome-Extension")

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type")

    # Allow iframe embedding for extensions only
    conn =
      if is_extension do
        conn
        |> put_resp_header("x-frame-options", "ALLOWALL")
        |> put_resp_header(
          "content-security-policy",
          "frame-ancestors 'self' chrome-extension: moz-extension:"
        )
      else
        conn
        |> put_resp_header("x-frame-options", "SAMEORIGIN")
        |> put_resp_header("content-security-policy", "frame-ancestors 'self'")
      end

    handle_preflight(conn)
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(200, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
