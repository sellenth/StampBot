defmodule DragNStamp.Security.Caller do
  @moduledoc """
  Derives opaque caller buckets from transport peers or explicitly trusted proxies.

  Configure `:trusted_proxy_cidrs` with exact trusted proxy networks; the default
  is empty. A trusted transport peer may provide one X-Forwarded-For header. The
  chain is traversed right-to-left, discarding only allowlisted proxy addresses.
  Malformed configuration, duplicate/invalid headers, and all-trusted chains
  fall back to the transport peer, which can group users behind the same proxy.

  Explicit `:proxy_mode, :railway` uses Railway's overwritten X-Real-IP header.
  Enable it only when all untrusted HTTP traffic must traverse Railway's edge.
  Exactly one strict IP address is accepted; missing or malformed headers fall
  back to the peer. This mode relies on the verified ingress boundary and does
  not infer trusted networks from private addresses or request headers.
  """

  import Bitwise

  @max_header_bytes 2048
  @max_chain_entries 16
  @max_proxy_cidrs 64

  def from_connection(peer_address, x_headers) do
    case Application.get_env(:drag_n_stamp, :proxy_mode, :cidr) do
      :railway ->
        case railway_address(x_headers) do
          {:ok, client} -> from_ip(client)
          _ -> from_ip(peer_address)
        end

      :cidr ->
        from_forwarded_chain(peer_address, x_headers)

      _ ->
        from_ip(peer_address)
    end
  end

  defp from_forwarded_chain(peer_address, x_headers) do
    with {:ok, networks} <- trusted_networks(),
         true <- trusted?(peer_address, networks),
         {:ok, chain} <- forwarded_chain(x_headers),
         [client | _] <- Enum.drop_while(Enum.reverse(chain), &trusted?(&1, networks)) do
      from_ip(client)
    else
      _ -> from_ip(peer_address)
    end
  end

  def from_ip(address) do
    case address_value(address) do
      {:ok, _, _} ->
        normalized =
          case address do
            {0, 0, 0, 0, 0, 0xFFFF, high, low} ->
              {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

            {a, b, c, d, _, _, _, _} ->
              {a, b, c, d, 0, 0, 0, 0}

            _ ->
              address
          end

        hash(:inet.ntoa(normalized) |> to_string())

      _ ->
        hash("unknown-peer")
    end
  end

  def internal, do: hash("internal")

  defp trusted_networks do
    configured = Application.get_env(:drag_n_stamp, :trusted_proxy_cidrs, [])

    if is_list(configured) and length(configured) <= @max_proxy_cidrs do
      Enum.reduce_while(configured, {:ok, []}, fn cidr, {:ok, networks} ->
        case parse_cidr(cidr) do
          {:ok, network} -> {:cont, {:ok, [network | networks]}}
          _ -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp parse_cidr(cidr) when is_binary(cidr) and byte_size(cidr) <= 64 do
    with [address, prefix] <- String.split(cidr, "/"),
         {prefix, ""} <- Integer.parse(prefix),
         {:ok, address} <- parse_address(address),
         {:ok, value, bits} <- address_value(address),
         true <- prefix >= 0 and prefix <= bits do
      {:ok, {value >>> (bits - prefix), bits, prefix}}
    else
      _ -> :error
    end
  end

  defp parse_cidr(_), do: :error

  defp trusted?(address, networks) do
    case address_value(address) do
      {:ok, value, bits} ->
        Enum.any?(networks, fn
          {network, ^bits, prefix} -> value >>> (bits - prefix) == network
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp forwarded_chain(headers) when is_list(headers) do
    values =
      Enum.flat_map(headers, fn
        {name, value} when is_binary(name) ->
          if String.downcase(name) == "x-forwarded-for", do: [value], else: []

        _ ->
          []
      end)

    case values do
      [value] when is_binary(value) and byte_size(value) <= @max_header_bytes ->
        parts = String.split(value, ",")

        if length(parts) <= @max_chain_entries and not String.contains?(value, ["\r", "\n"]) do
          Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, addresses} ->
            case parse_address(String.trim(part)) do
              {:ok, address} -> {:cont, {:ok, [address | addresses]}}
              _ -> {:halt, :error}
            end
          end)
          |> case do
            {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
            _ -> :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp forwarded_chain(_), do: :error

  defp railway_address(headers) when is_list(headers) do
    values =
      for {name, value} <- headers,
          is_binary(name),
          String.downcase(name) == "x-real-ip",
          do: value

    case values do
      [value] when is_binary(value) and byte_size(value) <= 45 ->
        # Erlang's strict parser accepts IPv6 zone suffixes; HTTP client
        # addresses here must contain only the address itself.
        if Regex.match?(~r/\A[0-9A-Fa-f:.]+\z/, value), do: parse_address(value), else: :error

      _ ->
        :error
    end
  end

  defp railway_address(_), do: :error

  defp parse_address(address) when is_binary(address) and byte_size(address) <= 45 do
    if String.valid?(address),
      do: :inet.parse_strict_address(String.to_charlist(address)),
      else: :error
  end

  defp parse_address(_), do: :error

  defp address_value(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    width = if tuple_size(address) == 4, do: 8, else: 16
    components = Tuple.to_list(address)

    if Enum.all?(components, &(is_integer(&1) and &1 >= 0 and &1 < 1 <<< width)) do
      {:ok, Enum.reduce(components, 0, fn part, acc -> acc <<< width ||| part end),
       width * length(components)}
    else
      :error
    end
  end

  defp address_value(_), do: :error

  defp hash(value) do
    key =
      Application.fetch_env!(:drag_n_stamp, DragNStampWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, key, "submission-caller:" <> value)
    |> Base.encode16(case: :lower)
  end
end
