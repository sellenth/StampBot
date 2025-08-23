defmodule DragNStampWeb.Plugs.CustomHeaders do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    # Remove the problematic Permissions-Policy header entirely
    |> delete_resp_header("permissions-policy")
    # Add back only the headers we want
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
  end
end
