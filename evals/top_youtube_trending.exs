defmodule StampBot.TopYouTubeTrendingEval do
  @moduledoc false

  alias DragNStamp.Timestamps.{CostEstimator, GeminiClient, Prompts}

  @snapshot_source "https://trendtube.adaptivemind.tech/"
  @snapshot_at "2026-08-17T19:00:00-07:00"

  @videos [
    %{
      rank: 1,
      id: "_NlOIjOByUg",
      duration_seconds: 149,
      title: "LIL NAAY - PERRA (VIDEO OFICIAL)",
      channel: "Lil Naay"
    },
    %{
      rank: 2,
      id: "X1aFkAkFASk",
      duration_seconds: 130,
      title: "Avengers: Doomsday | Special Look | In Theaters December 18",
      channel: "Marvel Entertainment"
    },
    %{
      rank: 5,
      id: "t2I_6p1TwfM",
      duration_seconds: 1_636,
      title: "AVENGERS DOOMSDAY TRAILER BREAKDOWN! Easter Eggs & Details You Missed | D23 2026",
      channel: "New Rockstars"
    },
    %{
      rank: 8,
      id: "5qm6_DoM1Pc",
      duration_seconds: 224,
      title: "Kingdom Hearts 4 - Official Coco Extended Gameplay Trailer | D23 2026",
      channel: "IGN"
    },
    %{
      rank: 10,
      id: "7aYqQN2IzS8",
      duration_seconds: 421,
      title: "Waterfall - A Minecraft Music Video",
      channel: "Rainimator"
    }
  ]

  @variants [
    %{
      name: "old_models",
      video_model: "gemini-2.5-flash",
      video_thinking_level: nil,
      text_model: "gemini-3-flash-preview",
      text_thinking_level: nil
    },
    %{
      name: "modernized",
      video_model: "gemini-3.7-flash",
      video_thinking_level: "medium",
      text_model: "gemini-3.5-flash-lite",
      text_thinking_level: "low"
    }
  ]

  def run do
    load_dotenv()
    api_key = System.fetch_env!("GEMINI_API_KEY")
    ensure_runtime_started()
    videos = Enum.take(@videos, eval_limit())

    IO.puts(
      "Evaluating #{length(videos)} current U.S. top-ten YouTube videos across #{length(@variants)} model configurations"
    )

    results =
      Enum.flat_map(videos, fn video ->
        Enum.map(@variants, fn variant ->
          IO.puts("rank=#{video.rank} variant=#{variant.name} starting title=#{video.title}")
          result = evaluate(video, variant, api_key)

          IO.puts(
            "rank=#{video.rank} variant=#{variant.name} status=#{result.status} score=#{result.score || 0} duration_ms=#{result.duration_ms} estimated_cost_usd=#{format_cost(result.estimated_cost_usd)}"
          )

          if result.status == "error", do: IO.puts("error=#{result.error}")

          result
        end)
      end)

    report = %{
      snapshot_at: @snapshot_at,
      snapshot_source: @snapshot_source,
      sample_size: length(videos),
      results: results,
      summary: summarize(results)
    }

    IO.puts("\nEVAL_REPORT_JSON")
    IO.puts(Jason.encode!(report, pretty: true))
  end

  defp evaluate(video, variant, api_key) do
    started_at = System.monotonic_time()
    url = "https://www.youtube.com/watch?v=#{video.id}"

    video_opts = [
      model: variant.video_model,
      thinking_level: variant.video_thinking_level,
      max_seconds: video.duration_seconds,
      generation_config: %{"mediaResolution" => "MEDIA_RESOLUTION_LOW"},
      max_attempts: 2,
      receive_timeout: 300_000
    ]

    with {:ok, video_result} <-
           GeminiClient.timestamps_detailed_with_retry(
             Prompts.video(video.channel),
             api_key,
             url,
             video_opts
           ),
         {:ok, text_result} <-
           GeminiClient.text_only_detailed(
             Prompts.distillation(video_result.content),
             api_key,
             model: variant.text_model,
             thinking_level: variant.text_thinking_level,
             max_seconds: video.duration_seconds,
             max_attempts: 2,
             receive_timeout: 300_000
           ) do
      duration_ms = elapsed_ms(started_at)
      grade = grade(text_result.timestamps, video.duration_seconds)

      %{
        status: "ok",
        score: grade.score,
        rank: video.rank,
        video_id: video.id,
        title: video.title,
        duration_seconds: video.duration_seconds,
        variant: variant.name,
        video_model: video_result.model_version || video_result.model,
        text_model: text_result.model_version || text_result.model,
        video_thinking_level: variant.video_thinking_level,
        text_thinking_level: variant.text_thinking_level,
        primary_timestamp_count: length(video_result.timestamps),
        final_timestamp_count: length(text_result.timestamps),
        final_timestamps: text_result.content,
        grade: grade,
        usage: %{
          video: video_result.usage,
          text: text_result.usage
        },
        attempts: %{
          video: video_result.attempts,
          text: text_result.attempts
        },
        duration_ms: duration_ms,
        estimated_cost_usd: total_estimated_cost([video_result, text_result])
      }
    else
      {:error, reason} ->
        %{
          status: "error",
          score: nil,
          rank: video.rank,
          video_id: video.id,
          title: video.title,
          duration_seconds: video.duration_seconds,
          variant: variant.name,
          error: inspect(reason),
          duration_ms: elapsed_ms(started_at),
          estimated_cost_usd: 0.0
        }
    end
  rescue
    error ->
      %{
        status: "error",
        score: nil,
        rank: video.rank,
        video_id: video.id,
        title: video.title,
        duration_seconds: video.duration_seconds,
        variant: variant.name,
        error: Exception.format(:error, error, __STACKTRACE__),
        duration_ms: 0,
        estimated_cost_usd: 0.0
      }
  end

  defp grade(timestamps, duration_seconds) do
    count = length(timestamps)
    {target_min, target_max} = target_count(duration_seconds)
    first_seconds = timestamps |> List.first() |> Map.fetch!(:seconds)
    last_seconds = timestamps |> List.last() |> Map.fetch!(:seconds)
    coverage = Float.round(last_seconds / duration_seconds, 3)

    title_word_ratio =
      timestamps
      |> Enum.count(fn timestamp ->
        word_count = timestamp.title |> String.split(~r/\s+/, trim: true) |> length()
        word_count in 8..12
      end)
      |> Kernel./(count)
      |> Float.round(3)

    count_score = if count in target_min..target_max, do: 20, else: 10
    coverage_score = min(round(20 * min(coverage / 0.8, 1.0)), 20)
    starts_score = if first_seconds <= max(15, round(duration_seconds * 0.05)), do: 10, else: 0
    word_score = round(20 * title_word_ratio)

    unwatched? =
      Enum.any?(timestamps, fn timestamp ->
        String.contains?(String.upcase(timestamp.title), "UNWATCHED")
      end)

    score =
      20 + count_score + coverage_score + starts_score + word_score +
        if(unwatched?, do: 0, else: 10)

    %{
      score: min(score, 100),
      count: count,
      target_count: [target_min, target_max],
      first_seconds: first_seconds,
      last_seconds: last_seconds,
      timeline_coverage: coverage,
      titles_with_8_to_12_words_ratio: title_word_ratio,
      unwatched: unwatched?
    }
  end

  defp target_count(seconds) when seconds <= 60, do: {1, 1}
  defp target_count(seconds) when seconds <= 5 * 60, do: {2, 3}
  defp target_count(seconds) when seconds <= 10 * 60, do: {6, 8}
  defp target_count(seconds) when seconds <= 20 * 60, do: {8, 12}
  defp target_count(_seconds), do: {10, 14}

  defp summarize(results) do
    Enum.map(@variants, fn variant ->
      selected = Enum.filter(results, &(&1.variant == variant.name))
      successful = Enum.filter(selected, &(&1.status == "ok"))

      %{
        variant: variant.name,
        successful: length(successful),
        failed: length(selected) - length(successful),
        average_score: average(Enum.map(successful, & &1.score)),
        average_duration_ms: average(Enum.map(successful, & &1.duration_ms)),
        total_estimated_cost_usd:
          successful
          |> Enum.map(& &1.estimated_cost_usd)
          |> Enum.sum()
          |> Kernel.*(1.0)
          |> Float.round(6)
      }
    end)
  end

  defp average([]), do: nil
  defp average(values), do: values |> Enum.sum() |> Kernel./(length(values)) |> Float.round(2)

  defp total_estimated_cost(results) do
    results
    |> Enum.map(&CostEstimator.estimate_usd/1)
    |> Enum.reduce(nil, &CostEstimator.add/2)
    |> case do
      nil -> 0.0
      cost -> Decimal.to_float(cost)
    end
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp format_cost(cost), do: :erlang.float_to_binary(cost, decimals: 6)

  defp eval_limit do
    case Integer.parse(System.get_env("EVAL_LIMIT", "5")) do
      {limit, ""} when limit in 1..5 -> limit
      _ -> 5
    end
  end

  defp ensure_runtime_started do
    {:ok, _} = Application.ensure_all_started(:telemetry)

    case Process.whereis(DragNStamp.Finch) do
      nil ->
        {:ok, _pid} = Finch.start_link(name: DragNStamp.Finch)

      _pid ->
        :ok
    end
  end

  defp load_dotenv do
    if File.exists?(".env") do
      ".env"
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)

            if key != "" and value != "" and System.get_env(key) == nil do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end)
    end
  end
end

StampBot.TopYouTubeTrendingEval.run()
