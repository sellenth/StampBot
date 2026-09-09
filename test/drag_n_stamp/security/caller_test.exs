defmodule DragNStamp.Security.CallerTest do
  use ExUnit.Case, async: false
  alias DragNStamp.Security.Caller

  @peer {10, 0, 0, 8}
  @client {203, 0, 113, 19}

  setup do
    previous = Application.fetch_env(:drag_n_stamp, :trusted_proxy_cidrs)
    Application.put_env(:drag_n_stamp, :trusted_proxy_cidrs, [])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:drag_n_stamp, :trusted_proxy_cidrs, value)
        :error -> Application.delete_env(:drag_n_stamp, :trusted_proxy_cidrs)
      end
    end)
  end

  test "default and untrusted peers cannot supply caller identity" do
    headers = [{"x-forwarded-for", "203.0.113.19"}]
    assert Caller.from_connection(@peer, headers) == Caller.from_ip(@peer)
    trust(["192.0.2.0/24"])
    assert Caller.from_connection(@peer, headers) == Caller.from_ip(@peer)
  end

  test "trusted chain selects the rightmost untrusted address and ignores spoofed left entries" do
    trust(["10.0.0.0/24", "192.0.2.10/32"])
    headers = [{"x-forwarded-for", "198.51.100.99, 203.0.113.19, 10.0.0.2, 192.0.2.10"}]
    assert Caller.from_connection(@peer, headers) == Caller.from_ip(@client)
  end

  test "unlisted rightmost proxy retains a restrictive shared bucket" do
    trust(["10.0.0.0/24"])
    headers = [{"x-forwarded-for", "203.0.113.19, 192.0.2.10"}]
    assert Caller.from_connection(@peer, headers) == Caller.from_ip({192, 0, 2, 10})
  end

  test "duplicate, invalid, empty, and oversized chains fall back to the peer" do
    trust(["10.0.0.0/24"])

    for headers <- [
          [],
          [{"x-forwarded-for", "203.0.113.19"}, {"X-Forwarded-For", "203.0.113.20"}],
          [{"x-forwarded-for", "garbage, 203.0.113.19"}],
          [{"x-forwarded-for", "203.0.113.19,"}],
          [{"x-forwarded-for", "unknown"}],
          [{"x-forwarded-for", "203.0.113.19:8080"}],
          [{"x-forwarded-for", <<255, 44>> <> "203.0.113.19"}],
          [{"x-forwarded-for", "203.0.113.19\r\n"}],
          [{"x-forwarded-for", String.duplicate("1", 2049)}],
          [{"x-forwarded-for", Enum.join(List.duplicate("203.0.113.19", 17), ",")}],
          [{"x-forwarded-for", "10.0.0.2, 10.0.0.3"}]
        ] do
      assert Caller.from_connection(@peer, headers) == Caller.from_ip(@peer)
    end
  end

  test "invalid proxy configuration fails closed including partial valid lists" do
    for networks <- [["10.0.0.0/33"], ["10.0.0.0/24", "garbage"], ["10.0.0.0"], nil] do
      trust(networks)

      assert Caller.from_connection(@peer, [{"x-forwarded-for", "203.0.113.19"}]) ==
               Caller.from_ip(@peer)
    end
  end

  test "IPv6 proxies match CIDRs while client addresses share a /64 bucket" do
    trust(["2001:db8:1::/48"])
    peer = {0x2001, 0xDB8, 1, 2, 0, 0, 0, 8}
    headers = [{"X-Forwarded-For", "2001:db8:2:3::19, 2001:db8:1:3::1"}]

    assert Caller.from_connection(peer, headers) ==
             Caller.from_ip({0x2001, 0xDB8, 2, 3, 0, 0, 0, 1})
  end

  test "IPv4-mapped IPv6 clients retain distinct IPv4 caller buckets" do
    assert Caller.from_ip({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7113}) ==
             Caller.from_ip(@client)

    refute Caller.from_ip({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7114}) ==
             Caller.from_ip(@client)
  end

  defp trust(networks), do: Application.put_env(:drag_n_stamp, :trusted_proxy_cidrs, networks)
end
