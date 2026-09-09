defmodule DragNStampWeb.Plugs.OperatorAuth do
  @moduledoc "Explicit bearer authentication for operator-only account actions."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:drag_n_stamp, :operator_token)

    supplied =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> nil
      end

    if is_binary(expected) and byte_size(expected) >= 32 and is_binary(supplied) and
         Plug.Crypto.secure_compare(
           :crypto.hash(:sha256, expected),
           :crypto.hash(:sha256, supplied)
         ) do
      assign(conn, :operator_authenticated, true)
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(
        401,
        Jason.encode!(%{status: "error", message: "Operator authentication required."})
      )
      |> halt()
    end
  end
end
