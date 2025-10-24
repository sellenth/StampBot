defmodule DragNStamp.YouTube.Captions do
  @moduledoc """
  Retrieves YouTube captions via `yt-dlp`, preferring human-authored subtitles
  and falling back to auto-generated transcripts when necessary.
  """

  require Logger

  alias Exyt

  @default_language "en"
  @sub_variants [
    {"--write-subs", :subtitles},
    {"--write-auto-subs", :auto_subtitles}
  ]
  @output_template "%(id)s.%(language)s.%(ext)s"
  @cue_header_regex ~r/^(?<start>\d{1,2}:\d{2}:\d{2}(?:[\.,]\d{3})?)\s+-->\s+(?<end>\d{1,2}:\d{2}:\d{2}(?:[\.,]\d{3})?)(?:\s+.*)?$/

  @type transcript_result ::
          {:ok, %{track: map(), segments: list(), context: map()}}
          | {:error, term(), map()}

  @doc """
  Fetches a transcript for the supplied `video_id`.
  """
  @spec fetch_transcript(String.t()) :: transcript_result()
  def fetch_transcript(video_id) when is_binary(video_id) do
    url = "https://www.youtube.com/watch?v=#{video_id}"
    cookies_path = cookies_path()
    language = caption_language()

    tmp_root =
      Path.join(System.tmp_dir!(), "drag-n-stamp-ytdlp-#{System.unique_integer([:positive])}")

    File.rm_rf(tmp_root)
    File.mkdir_p!(tmp_root)

    try do
      attempt_downloads(video_id, url, language, cookies_path, tmp_root)
    after
      File.rm_rf(tmp_root)
    end
  end

  def fetch_transcript(_), do: {:error, :invalid_video_id, %{stage: :input_validation}}

  defp attempt_downloads(video_id, url, language, cookies_path, tmp_root) do
    base_attempt = %{
      video_id: video_id,
      url: url,
      cookies_supplied: not is_nil(cookies_path),
      language: language
    }

    Enum.reduce_while(@sub_variants, {:error, :no_subtitles, [], base_attempt}, fn {flag, variant},
                                                                                   {:error,
                                                                                    _last_reason,
                                                                                    attempts,
                                                                                    base} ->
      case download_variant(url, language, cookies_path, tmp_root, flag, variant) do
        {:ok, track, segments, attempt_meta} ->
          context =
            base
            |> Map.merge(%{
              stage: :transcript_ready,
              fallback_used: true,
              source: :yt_dlp,
              chosen_variant: variant,
              segment_count: length(segments),
              attempts: Enum.reverse([attempt_meta | attempts])
            })

          {:halt, {:ok, %{track: track, segments: segments, context: context}}}

        {:error, reason, attempt_meta} ->
          {:cont, {:error, reason, [attempt_meta | attempts], base}}
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, attempts, base} ->
        context =
          base
          |> Map.merge(%{
            stage: :yt_dlp_attempts,
            fallback_used: true,
            source: :yt_dlp,
            attempts: Enum.reverse(attempts),
            last_reason: inspect(reason)
          })

        {:error, reason, context}
    end
  end

  defp download_variant(url, language, cookies_path, tmp_root, flag, variant) do
    variant_dir = Path.join(tmp_root, Atom.to_string(variant))
    File.rm_rf(variant_dir)
    File.mkdir_p!(variant_dir)

    params =
      [
        "--skip-download",
        #flag,
        "--write-auto-sub",
        "--convert-subs=vtt",
        #language,
        #"--sub-format",
        #"vtt",
        "--quiet",
        "--output",
        Path.join(variant_dir, @output_template)
      ] ++ cookies_args(cookies_path)

      IO.puts(params)

    result =
      case Exyt.ytdlp(params, url) do
        {:ok, _output} ->
          with {:ok, subtitle_path} <- locate_subtitle_file(variant_dir),
               {:ok, segments, parse_meta} <- parse_vtt(subtitle_path) do
            track =
              %{
                "source" => "yt_dlp",
                "variant" => Atom.to_string(variant),
                "language" => parse_meta.language || language,
                "filename" => Path.basename(subtitle_path)
              }

            attempt_meta =
              %{
                variant: Atom.to_string(variant),
                status: :ok,
                file: Path.basename(subtitle_path),
                language: track["language"],
                segment_count: length(segments)
              }

            {:ok, track, segments, attempt_meta}
          else
            {:error, reason} ->
              {:error, reason,
               %{
                 variant: Atom.to_string(variant),
                 status: :error,
                 reason: inspect(reason)
               }}
          end

        {:error, reason} ->
          {:error, {:yt_dlp_failed, reason},
           %{
             variant: Atom.to_string(variant),
             status: :error,
             reason: inspect(reason)
           }}
      end

    File.rm_rf(variant_dir)
    result
  end

  @cookie_term_key {:drag_n_stamp, :yt_dlp_cookies_path}

  defp cookies_path do
    case System.get_env("YTDLP_COOKIES_PATH") do
      path when is_binary(path) and path != "" ->
        validate_cookie_file(path)

      _ ->
        cookies_path_from_b64()
    end
  end

  defp cookies_path_from_b64 do
    case :persistent_term.get(@cookie_term_key, :unset) do
      {:ok, path} ->
        path

      :unset ->
        decoded =
          case System.get_env("YTDLP_COOKIES_B64") do
            encoded when is_binary(encoded) and encoded != "" ->
              with {:ok, binary} <- Base.decode64(encoded),
                   {:ok, maybe_plain} <- maybe_gunzip(binary) do
                {:ok, maybe_plain}
              else
                {:error, reason} ->
                  Logger.warning("""
                  Failed to decode YTDLP_COOKIES_B64 environment variable: #{inspect(reason)}
                  """)

                  :error
              end

            _ ->
              :missing
          end

        case decoded do
          {:ok, contents} ->
            path =
              Path.join(
                System.tmp_dir!(),
                "drag-n-stamp-ytdlp-cookies-#{System.unique_integer([:positive])}.txt"
              )

            with :ok <- File.write(path, contents),
                 :ok <- File.chmod(path, 0o600) do
              :persistent_term.put(@cookie_term_key, {:ok, path})
              path
            else
              {:error, reason} ->
                Logger.warning("""
                Failed to materialise cookies from YTDLP_COOKIES_B64: #{inspect(reason)}
                """)

                :persistent_term.put(@cookie_term_key, :error)
                nil

              other ->
                Logger.warning("""
                Unexpected result writing cookies from YTDLP_COOKIES_B64: #{inspect(other)}
                """)

                :persistent_term.put(@cookie_term_key, :error)
                nil
            end

          :missing ->
            :persistent_term.put(@cookie_term_key, :missing)
            nil

          :error ->
            :persistent_term.put(@cookie_term_key, :error)
            nil
        end

      :missing ->
        nil

      :error ->
        nil
    end
  end

  defp validate_cookie_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        path

      {:ok, %File.Stat{type: type}} ->
        Logger.warning("""
        YTDLP_COOKIES_PATH points to a non-regular file (#{type}). Ignoring cookies file.
        """)

        nil

      {:error, reason} ->
        Logger.warning("""
        Unable to read cookies file at #{path}: #{inspect(reason)}.
        """)

        nil
    end
  end

  defp caption_language do
    System.get_env("YTDLP_CAPTION_LANG", @default_language)
  end

  defp cookies_args(nil), do: []
  defp cookies_args(path), do: ["--cookies", path]

  defp maybe_gunzip(<<0x1F, 0x8B, _rest::binary>> = binary) do
    try do
      {:ok, :zlib.gunzip(binary)}
    rescue
      error ->
        {:error, {:gunzip_failed, error}}
    end
  end

  defp maybe_gunzip(binary) when is_binary(binary), do: {:ok, binary}
  defp maybe_gunzip(_), do: {:error, :invalid_binary}

  defp locate_subtitle_file(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".vtt"))
        |> Enum.sort()
        |> case do
          [] -> {:error, :subtitle_file_missing}
          [first | _] -> {:ok, Path.join(dir, first)}
        end

      {:error, reason} ->
        {:error, {:subtitle_directory_error, reason}}
    end
  end

  defp parse_vtt(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, cues} <- extract_cues(contents) do
      segments =
        cues
        |> Enum.map(fn %{start: start_ms, end: end_ms, text: text} ->
          %{start_ms: start_ms, end_ms: end_ms, text: text}
        end)
        |> Enum.reject(&(&1.text == ""))

      if segments == [] do
        {:error, :no_segments}
      else
        {:ok, segments, %{language: infer_language(path)}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_cues(contents) do
    blocks =
      contents
      |> String.split(~r/\r?\n\r?\n/, trim: true)

    cues =
      blocks
      |> Enum.reduce([], fn block, acc ->
        case parse_block(block) do
          {:ok, cue} ->
            [cue | acc]

          :skip ->
            acc

          {:error, reason} ->
            Logger.debug(fn -> "Skipping invalid VTT block: #{inspect(reason)}" end)
            acc
        end
      end)
      |> Enum.reverse()

    if cues == [] do
      {:error, :no_cues}
    else
      {:ok, cues}
    end
  end

  defp parse_block(block) do
    lines =
      block
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        :skip

      [single] ->
        if metadata_line?(single) do
          :skip
        else
          parse_cue_lines(lines)
        end

      [first | _] = cue_lines ->
        if metadata_line?(first) do
          :skip
        else
          parse_cue_lines(cue_lines)
        end
    end
  end

  defp metadata_line?(line) do
    String.starts_with?(line, "WEBVTT") or String.starts_with?(line, "NOTE")
  end

  defp parse_cue_lines([first | rest]) do
    {header_line, text_lines} =
      cond do
        Regex.match?(@cue_header_regex, first) ->
          {first, rest}

        length(rest) > 0 and Regex.match?(@cue_header_regex, hd(rest)) ->
          {hd(rest), tl(rest)}

        true ->
          {nil, []}
      end

    with true <- is_binary(header_line) and header_line != "",
         {:ok, start_ms, end_ms} <- parse_timecodes(header_line) do
      text =
        text_lines
        |> Enum.map(&strip_tags/1)
        |> Enum.map(&maybe_unescape_entities/1)
        |> Enum.join(" ")
        |> normalize_whitespace()

      {:ok, %{start: start_ms, end: end_ms, text: text}}
    else
      _ -> {:error, :invalid_cue}
    end
  end

  defp parse_timecodes(header_line) do
    case Regex.named_captures(@cue_header_regex, header_line) do
      %{"start" => start, "end" => finish} ->
        with {:ok, start_ms} <- timecode_to_ms(start),
             {:ok, end_ms} <- timecode_to_ms(finish) do
          {:ok, start_ms, end_ms}
        end

      _ ->
        {:error, :invalid_timecode}
    end
  end

  defp timecode_to_ms(time) do
    clean = String.replace(time, ",", ".")

    case String.split(clean, ":") do
      [mm, ss] ->
        with {:ok, minutes} <- int_from_string(mm),
             {:ok, seconds} <- float_from_string(ss) do
          {:ok, to_ms(0, minutes, seconds)}
        end

      [hh, mm, ss] ->
        with {:ok, hours} <- int_from_string(hh),
             {:ok, minutes} <- int_from_string(mm),
             {:ok, seconds} <- float_from_string(ss) do
          {:ok, to_ms(hours, minutes, seconds)}
        end

      _ ->
        {:error, :invalid_time_parts}
    end
  end

  defp int_from_string(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end

  defp float_from_string(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      {float, _rest} -> {:ok, float}
      :error -> {:error, :invalid_float}
    end
  end

  defp to_ms(hours, minutes, seconds_float) do
    total_seconds = hours * 3600 + minutes * 60 + seconds_float
    round(total_seconds * 1000)
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_tags(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
  end

  defp maybe_unescape_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp infer_language(path) do
    path
    |> Path.basename()
    |> String.split(".")
    |> Enum.drop(1)
    |> List.first()
  end
end
