defmodule DragNStampWeb.McpController do
  @moduledoc "Stateless MCP Streamable HTTP with JSON responses and no server-initiated stream."
  use DragNStampWeb, :controller
  alias DragNStamp.Plugin
  alias DragNStamp.Plugin.Usage

  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]

  plug :validate_transport

  def handle(%{method: "POST"} = conn, _params), do: dispatch(conn, conn.body_params)

  def handle(%{method: "OPTIONS"} = conn, _params) do
    conn
    |> put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS")
    |> send_resp(204, "")
  end

  def handle(conn, _params) do
    conn |> put_resp_header("allow", "POST, OPTIONS") |> send_resp(405, "")
  end

  defp dispatch(conn, %{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    cond do
      not Map.has_key?(request, "id") ->
        send_resp(conn, 202, "")

      not (is_binary(request["id"]) or is_integer(request["id"])) ->
        rpc_error(conn, nil, -32600, "Invalid request", 400)

      Map.has_key?(request, "params") and not is_map(request["params"]) ->
        rpc_error(conn, request["id"], -32602, "Parameters must be an object")

      true ->
        request(conn, request["id"], method, Map.get(request, "params", %{}))
    end
  end

  defp dispatch(conn, _), do: rpc_error(conn, nil, -32600, "Expected one JSON-RPC request", 400)

  defp request(conn, id, "initialize", %{
         "protocolVersion" => version,
         "capabilities" => capabilities,
         "clientInfo" => %{"name" => name, "version" => client_version}
       })
       when is_binary(version) and is_map(capabilities) and is_binary(name) and
              is_binary(client_version) do
    rpc_result(conn, id, %{
      protocolVersion: if(version in @versions, do: version, else: hd(@versions)),
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "stampbot", version: "0.1.0"},
      instructions: Plugin.instructions()
    })
  end

  defp request(conn, id, "initialize", _),
    do: rpc_error(conn, id, -32602, "Invalid initialization parameters")

  defp request(conn, id, "ping", _params), do: rpc_result(conn, id, %{})

  defp request(conn, id, "tools/list", _params),
    do: rpc_result(conn, id, %{tools: Plugin.tools()})

  defp request(conn, id, "tools/call", %{"name" => name} = params)
       when name in ["generate_chapters", "get_chapters"] do
    context = Usage.context(conn, params["_meta"])
    rpc_result(conn, id, Plugin.call(name, Map.get(params, "arguments", %{}), context))
  end

  defp request(conn, id, "tools/call", _),
    do: rpc_error(conn, id, -32602, "Unknown tool or missing tool name")

  defp request(conn, id, _method, _params), do: rpc_error(conn, id, -32601, "Method not found")

  defp validate_transport(conn, _opts) do
    origins = [DragNStampWeb.Endpoint.url(), "https://chatgpt.com"]
    origin = get_req_header(conn, "origin")
    versions = get_req_header(conn, "mcp-protocol-version")
    conn = conn |> put_resp_header("cache-control", "no-store")

    cond do
      not Usage.config(:enabled) ->
        conn
        |> rpc_error(nil, -32000, "StampBot plugin is temporarily unavailable", 503)
        |> halt()

      origin != [] and not (length(origin) == 1 and hd(origin) in origins) ->
        conn |> rpc_error(nil, -32000, "Origin not allowed", 403) |> halt()

      versions != [] and not (length(versions) == 1 and hd(versions) in @versions) ->
        conn |> rpc_error(nil, -32000, "Unsupported MCP protocol version", 400) |> halt()

      true ->
        conn
        |> put_resp_header(
          "access-control-allow-origin",
          if(origin == [], do: "https://chatgpt.com", else: hd(origin))
        )
        |> put_resp_header("vary", "origin")
        |> put_resp_header(
          "access-control-allow-headers",
          "content-type, mcp-protocol-version, mcp-session-id"
        )
    end
  end

  defp rpc_result(conn, id, result), do: json(conn, %{jsonrpc: "2.0", id: id, result: result})

  defp rpc_error(conn, id, code, message, status \\ 200),
    do:
      conn
      |> put_status(status)
      |> json(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
end
