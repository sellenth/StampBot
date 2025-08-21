defmodule DragNStampWeb.Plugs.ExtensionHeaders do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check if this is an extension request
    is_extension = String.contains?(conn.request_path, "mode=extension") or 
                  String.contains?(conn.query_string, "mode=extension")
    
    if is_extension do
      conn
      |> put_resp_header("x-frame-options", "ALLOWALL")
      |> put_resp_header("content-security-policy", "frame-ancestors 'self' chrome-extension: moz-extension: chrome-untrusted:")
    else
      conn
    end
  end
end