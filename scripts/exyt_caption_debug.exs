#!/usr/bin/env elixir

# A small helper for verifying that `exyt_dlp` and `yt-dlp` can be used to fetch
# captions for a given video URL. Run with:
#
#     mix run scripts/exyt_caption_debug.exs --url https://youtu.be/<id>
#
# Options:
#   --url <string>   (required) Video URL that yt-dlp understands
#   --lang <string>  Preferred subtitle language (default: "en")
#   --raw            Print the subtitle file contents without any processing
#
# The script will try to download regular subtitles first and fall back to
# auto-generated subtitles. Captions are printed to STDOUT.

alias Exyt

defmodule Scripts.ExytCaptionDebug do
  @sub_variants [
    {"--write-subs", :subtitles},
    {"--write-auto-subs", :auto_subtitles}
  ]

  @output_template "%(id)s.%(language)s.%(ext)s"

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [url: :string, lang: :string, raw: :boolean, cookies: :string],
        aliases: [u: :url, l: :lang, c: :cookies]
      )

    case {opts[:url] || List.first(args), invalid} do
      {nil, _} ->
        usage!("Missing URL.")

      {url, []} ->
        language = opts[:lang] || "en"
        raw? = opts[:raw] || false
        cookies_path = opts[:cookies] || System.get_env("YTDLP_COOKIES_PATH")
        run(url, language, raw?, cookies_path)

      {_, _invalid} ->
        usage!("Unrecognised options: #{inspect(invalid)}")
    end
  end

  defp usage!(reason) do
    IO.puts(:stderr, reason)
    IO.puts(:stderr, """
    Usage:
      mix run scripts/exyt_caption_debug.exs --url <video_url> [--lang <code>] [--raw] [--cookies <path>]
    """)

    System.halt(1)
  end

  defp run(url, language, raw?, cookies_path) do
    validate_cookies!(cookies_path)

    tmp_root =
      Path.join(System.tmp_dir!(), "exyt-caption-debug-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)

    result =
      Enum.reduce_while(@sub_variants, {:error, :no_subtitles}, fn {flag, label}, _acc ->
        tmp_dir = Path.join(tmp_root, Atom.to_string(label))
        File.rm_rf(tmp_dir)
        File.mkdir_p!(tmp_dir)

        case download_to(tmp_dir, url, language, flag, cookies_path) do
          {:ok, path} -> {:halt, {:ok, path, label}}
          {:error, _reason} = error -> {:cont, error}
        end
      end)

    case result do
      {:ok, subtitle_path, variant} ->
        IO.puts("✔ Downloaded #{variant_label(variant)} to #{subtitle_path}")
        print_captions(subtitle_path, raw?)
        File.rm_rf(tmp_root)

      {:error, reason} ->
        IO.puts(:stderr, "✖ Failed to download subtitles: #{inspect(reason)}")
        File.rm_rf(tmp_root)
        System.halt(1)
    end
  end

  defp download_to(dir, url, language, flag, cookies_path) do
    params =
      [
        "--skip-download",
        #flag,
        "--write-auto-sub",
        "--convert-subs=vtt",
        #language,
        #"--sub-format",
        #"vtt",
        "--output",
        Path.join(dir, @output_template)
      ] ++ cookies_args(cookies_path)

      IO.puts(params)

    case Exyt.ytdlp(params, url) do
      {:ok, _output} ->
        dir
        |> File.ls()
        |> case do
          {:ok, files} ->
            files
            |> Enum.find(&String.ends_with?(&1, ".vtt"))
            |> case do
              nil -> {:error, :subtitle_file_missing}
              file -> {:ok, Path.join(dir, file)}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_captions(path, true) do
    case File.read(path) do
      {:ok, contents} ->
        IO.puts(contents)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to read #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_captions(path, false) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> vtt_to_lines()
        |> Enum.each(&IO.puts/1)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to read #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp vtt_to_lines(vtt) do
    vtt
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.reduce([], fn line, acc ->
      line
      |> String.trim()
      |> maybe_collect(acc)
    end)
    |> Enum.reverse()
    |> dedupe_consecutive()
  end

  defp maybe_collect("", acc), do: acc
  defp maybe_collect("WEBVTT" <> _rest, acc), do: acc
  defp maybe_collect("NOTE" <> _rest, acc), do: acc
  defp maybe_collect(line, acc) do
    cond do
      line =~ ~r/^\d+$/ -> acc
      line =~ ~r/^\d{2}:\d{2}:\d{2}\.?\d*\s+-->/ -> acc
      line =~ ~r/^(Kind|Language|Style|Region):/i -> acc
      true -> [strip_tags(line) | acc]
    end
  end

  defp strip_tags(line) do
    line
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&nbsp;", " ")
  end

  defp dedupe_consecutive(lines) do
    {result, _prev} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, prev} ->
        if line == prev do
          {acc, prev}
        else
          {[line | acc], line}
        end
      end)

    Enum.reverse(result)
  end

  defp variant_label(:subtitles), do: "human subtitles"
  defp variant_label(:auto_subtitles), do: "auto-generated subtitles"

  defp cookies_args(nil), do: []
  defp cookies_args(path), do: ["--cookies", path]

  defp validate_cookies!(nil), do: :ok

  defp validate_cookies!(path) do
    unless File.exists?(path) do
      IO.puts(:stderr, "Configured cookies file not found: #{path}")
      System.halt(1)
    end

    :ok
  end
end

Scripts.ExytCaptionDebug.main(System.argv())
