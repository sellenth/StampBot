defmodule DragNStamp.YouTube.Innertube do
  @moduledoc """
  Minimal client for YouTube's Innertube API used as a backup when the public
  `timedtext` caption endpoints fail.
  """

  require Logger

  @watch_url "https://www.youtube.com/watch"
  @transcript_url "https://www.youtube.com/youtubei/v1/get_transcript"

  @spec fetch_transcript(String.t()) ::
          {:ok, %{segments: list(), track: map(), context: map()}}
          | {:error, term(), map()}
  def fetch_transcript(video_id) when is_binary(video_id) do
    with {:ok, html} <- fetch_watch_page(video_id),
         {:ok, config} <- extract_config(html),
         {:ok, player} <- extract_player_response(html),
         {:ok, tracks} <- extract_caption_tracks(player),
         {:ok, track} <- choose_track(tracks),
         {:ok, params} <- extract_params(track),
         {:ok, segments} <- request_transcript(video_id, config, params) do
      context =
        %{
          stage: :innertube_transcript,
          track_language_code: Map.get(track, "languageCode"),
          track_kind: Map.get(track, "kind"),
          innertube_client: get_in(config, ["INNERTUBE_CONTEXT", "client", "clientName"]),
          innertube_version: get_in(config, ["INNERTUBE_CONTEXT", "client", "clientVersion"])
        }
        |> maybe_put("caption_count", length(tracks))

      {:ok,
       %{
         segments: segments,
         track: track,
         context: context
       }}
    else
      {:error, reason} ->
        {:error, reason, %{stage: :innertube}}

      {:error, reason, context} ->
        {:error, reason, context}
    end
  end

  def fetch_transcript(_), do: {:error, :invalid_video_id, %{stage: :innertube_input_validation}}

  defp fetch_watch_page(video_id) do
    params =
      URI.encode_query(%{
        "v" => video_id,
        "hl" => "en"
      })

    url = @watch_url <> "?" <> params

    request =
      Finch.build(:get, url, [
        {"User-Agent", user_agent()},
        {"Accept-Language", "en-US,en;q=0.8"},
        {"Accept", "text/html"}
      ])

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:watch_fetch_failed, status},
         %{
           stage: :innertube_watch_fetch,
           status: status,
           body_preview: truncate(body)
         }}

      {:error, reason} ->
        {:error, {:watch_request_error, reason},
         %{stage: :innertube_watch_fetch, reason: inspect(reason)}}
    end
  end

  defp extract_config(html) when is_binary(html) do
    case Regex.run(~r/ytcfg\.set\(({.*?})\);/s, html, capture: :all_but_first) do
      [config_json | _] ->
        case Jason.decode(config_json) do
          {:ok, %{"INNERTUBE_API_KEY" => _key} = config} ->
            {:ok, config}

          {:ok, decoded} ->
            {:error, :missing_innertube_config,
             %{
               stage: :innertube_config,
               available_keys: Map.keys(decoded)
             }}

          {:error, reason} ->
            {:error, {:config_decode_failed, reason}, %{stage: :innertube_config}}
        end

      _ ->
        {:error, :config_not_found, %{stage: :innertube_config}}
    end
  end

  defp extract_config(_), do: {:error, :config_not_found, %{stage: :innertube_config}}

  defp extract_player_response(html) when is_binary(html) do
    with {:ok, json} <- extract_js_assignment(html, "ytInitialPlayerResponse"),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      {:error, {:assignment_not_found, _marker}} ->
        {:error, :player_response_not_found, %{stage: :innertube_player}}

      {:error, {:balanced_json_not_found, reason}} ->
        {:error, {:player_json_not_found, reason}, %{stage: :innertube_player}}

      {:error, reason} ->
        {:error, {:player_decode_failed, reason}, %{stage: :innertube_player}}
    end
  end

  defp extract_player_response(_),
    do: {:error, :player_response_not_found, %{stage: :innertube_player}}

  defp extract_caption_tracks(player) when is_map(player) do
    tracks =
      get_in(player, ["captions", "playerCaptionsTracklistRenderer", "captionTracks"]) || []

    case tracks do
      [] ->
        {:error, :no_caption_tracks,
         %{
           stage: :innertube_tracks,
           captions_present?: map_has?(player, "captions"),
           keys: player |> Map.get("captions", %{}) |> Map.keys()
         }}

      _ ->
        {:ok, tracks}
    end
  end

  defp extract_caption_tracks(_), do: {:error, :no_caption_tracks, %{stage: :innertube_tracks}}

  defp choose_track(tracks) when is_list(tracks) do
    track =
      tracks
      |> Enum.with_index()
      |> Enum.min_by(fn {track, index} ->
        {
          language_rank(Map.get(track, "languageCode")),
          kind_rank(Map.get(track, "kind")),
          default_rank(track),
          index
        }
      end)
      |> elem(0)

    {:ok, track}
  end

  defp choose_track(_), do: {:error, :invalid_tracks, %{stage: :innertube_choose_track}}

  defp extract_params(track) when is_map(track) do
    case Map.get(track, "params") do
      params when is_binary(params) ->
        {:ok, params}

      _ ->
        case Map.get(track, "baseUrl") do
          base_url when is_binary(base_url) ->
            case URI.parse(base_url) do
              %URI{query: query} when is_binary(query) ->
                query_params = URI.decode_query(query)

                case Map.get(query_params, "params") do
                  params when is_binary(params) ->
                    {:ok, params}

                  _ ->
                    {:error, :params_not_found,
                     %{stage: :innertube_params_from_base, available: Map.keys(query_params)}}
                end

              _ ->
                {:error, :params_not_found, %{stage: :innertube_params}}
            end

          _ ->
            {:error, :params_not_found,
             %{stage: :innertube_params, available_keys: Map.keys(track)}}
        end
    end
  end
@@
  defp request_transcript(_video_id, %{"INNERTUBE_API_KEY" => api_key, "INNERTUBE_CONTEXT" => context}, params)
       when is_binary(api_key) and is_map(context) and is_binary(params) do
    url = @transcript_url <> "?" <> URI.encode_query(%{"key" => api_key})
    body = %{"context" => context, "params" => params}

    request =
      Finch.build(:post, url, headers(),
        body: Jason.encode!(body)
      )

    case Finch.request(request, DragNStamp.Finch, receive_timeout: 20_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, payload} <- Jason.decode(body),
             {:ok, segments} <- parse_transcript(payload) do
          {:ok, segments}
        else
          {:error, reason} ->
            {:error, {:transcript_decode_failed, reason},
             %{stage: :innertube_transcript_decode, body_preview: truncate(body)}}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:transcript_http_error, status},
         %{
           stage: :innertube_transcript_request,
           status: status,
           body_preview: truncate(body)
         }}

      {:error, reason} ->
        {:error, {:transcript_request_failed, reason},
         %{stage: :innertube_transcript_request, reason: inspect(reason)}}
    end
  end

  defp request_transcript(_video_id, config, _params) do
    {:error, :invalid_innertube_config,
     %{
       stage: :innertube_transcript_request,
       keys: config |> Map.keys()
     }}
  end

  defp parse_transcript(%{"actions" => actions}) when is_list(actions) do
    cue_groups =
      actions
      |> Enum.flat_map(&extract_cue_groups/1)

    segments =
      cue_groups
      |> Enum.flat_map(&cue_group_to_segments/1)
      |> Enum.filter(&(&1.text != ""))

    if segments == [] do
      {:error, :empty_transcript}
    else
      {:ok, segments}
    end
  end

  defp parse_transcript(_), do: {:error, :unexpected_transcript_payload}

  defp extract_cue_groups(action) when is_map(action) do
    get_in(action, [
      "updateEngagementPanelAction",
      "content",
      "transcriptRenderer",
      "body",
      "transcriptBodyRenderer",
      "cueGroups"
    ]) || []
  end

  defp extract_cue_groups(_), do: []

  defp cue_group_to_segments(%{"transcriptCueGroupRenderer" => group}) when is_map(group) do
    group
    |> Map.get("cues", [])
    |> Enum.map(&cue_to_segment/1)
  end

  defp cue_group_to_segments(_), do: []

  defp cue_to_segment(%{"transcriptCueRenderer" => cue}) when is_map(cue) do
    start_ms = parse_int(Map.get(cue, "startOffsetMs"))
    duration_ms = parse_int(Map.get(cue, "durationMs"))
    text = extract_cue_text(cue)

    %{
      start_ms: start_ms,
      end_ms: start_ms + duration_ms,
      text: text
    }
  end

  defp cue_to_segment(_), do: %{start_ms: 0, end_ms: 0, text: ""}

  defp extract_cue_text(cue) do
    cue
    |> get_in(["cue", "simpleText"])
    |> case do
      nil ->
        cue
        |> get_in(["cue", "runs"])
        |> runs_to_text()

      text ->
        String.trim(text)
    end
  end

  defp runs_to_text(runs) when is_list(runs) do
    runs
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join()
    |> String.trim()
  end

  defp runs_to_text(_), do: ""

  defp headers do
    [
      {"Content-Type", "application/json"},
      {"User-Agent", user_agent()},
      {"Accept-Language", "en-US,en;q=0.8"}
    ]
  end

  defp user_agent do
    "Mozilla/5.0 (compatible; StampBot/1.0; +https://github.com/hal/stampbot)"
  end

  defp parse_int(nil), do: 0

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  defp truncate(nil), do: nil

  defp truncate(binary) when is_binary(binary) do
    if byte_size(binary) <= 200 do
      binary
    else
      binary
      |> binary_part(0, 200)
      |> Kernel.<>("…")
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, "", false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_rank(track) when is_map(track) do
    if Map.get(track, "isDefault", false) do
      0
    else
      1
    end
  end

  defp default_rank(_), do: 1

  defp language_rank(nil), do: 3

  defp language_rank(code) when is_binary(code) do
    normalized = String.downcase(code)

    cond do
      normalized in ["en", "en-us", "en-gb"] -> 0
      String.starts_with?(normalized, "en") -> 1
      true -> 2
    end
  end

  defp language_rank(_), do: 3

  defp kind_rank(nil), do: 0
  defp kind_rank("asr"), do: 1
  defp kind_rank(_other), do: 2

  defp map_has?(map, key) when is_map(map), do: Map.has_key?(map, key)
  defp map_has?(_, _), do: false

  defp extract_js_assignment(html, marker) when is_binary(html) and is_binary(marker) do
    search = marker <> " = "

    case String.split(html, search, parts: 2) do
      [_, rest] ->
        case take_balanced_json(rest) do
          {:ok, json, _remainder} -> {:ok, json}
          {:error, reason} -> {:error, {:balanced_json_not_found, reason}}
        end

      _ ->
        bracket_search = "window[\"" <> marker <> "\"] = "

        case String.split(html, bracket_search, parts: 2) do
          [_, rest] ->
            case take_balanced_json(rest) do
              {:ok, json, _remainder} -> {:ok, json}
              {:error, reason} -> {:error, {:balanced_json_not_found, reason}}
            end

          _ ->
            {:error, {:assignment_not_found, marker}}
        end
    end
  end

  defp take_balanced_json(binary) do
    case find_first_object(binary) do
      {:ok, rest} ->
        do_take_balanced(rest, 1, false, false, ["{"])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_first_object(<<>>), do: {:error, :opening_brace_not_found}
  defp find_first_object(<<"{", rest::binary>>), do: {:ok, rest}
  defp find_first_object(<<_char, rest::binary>>), do: find_first_object(rest)

  defp do_take_balanced(<<>>, _depth, _in_string, _escape?, _acc),
    do: {:error, :unterminated_json}

  defp do_take_balanced(binary, depth, in_string, escape?, acc) do
    <<char, rest::binary>> = binary

    cond do
      in_string and escape? ->
        do_take_balanced(rest, depth, true, false, [char | acc])

      in_string and char == ?\\ ->
        do_take_balanced(rest, depth, true, true, [char | acc])

      in_string and char == ?" ->
        do_take_balanced(rest, depth, false, false, [char | acc])

      in_string ->
        do_take_balanced(rest, depth, true, false, [char | acc])

      char == ?" ->
        do_take_balanced(rest, depth, true, false, [char | acc])

      char == ?{ ->
        do_take_balanced(rest, depth + 1, false, false, [char | acc])

      char == ?} ->
        new_depth = depth - 1

        if new_depth == 0 do
          json =
            acc
            |> Enum.reverse()
            |> IO.iodata_to_binary()
            |> Kernel.<>("}")

          {:ok, json, rest}
        else
          do_take_balanced(rest, new_depth, false, false, [char | acc])
        end

      true ->
        do_take_balanced(rest, depth, false, false, [char | acc])
    end
  end
end
