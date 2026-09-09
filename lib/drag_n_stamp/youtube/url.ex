defmodule DragNStamp.YouTube.URL do
  @moduledoc "Canonical identity for supported YouTube video links."

  @hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com)

  def parse(value) when is_binary(value) do
    uri = value |> String.trim() |> URI.parse()

    with true <- uri.scheme in ["http", "https"] and is_nil(uri.userinfo),
         id when is_binary(id) <- video_id(uri),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id) do
      {:ok, %{video_id: id, url: "https://www.youtube.com/watch?v=#{id}"}}
    else
      _ -> {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  def parse(_), do: {:error, :invalid_url}

  defp video_id(%URI{host: host, path: path, query: query}) when host in @hosts do
    case String.split(path || "", "/", trim: true) do
      ["watch"] -> URI.decode_query(query || "")["v"]
      [kind, id] when kind in ["shorts", "live", "embed"] -> id
      _ -> nil
    end
  end

  defp video_id(%URI{host: host, path: path}) when host in ["youtu.be", "www.youtu.be"] do
    case String.split(path || "", "/", trim: true) do
      [id] -> id
      _ -> nil
    end
  end

  defp video_id(_), do: nil
end
