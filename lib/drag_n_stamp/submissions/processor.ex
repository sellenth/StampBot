defmodule DragNStamp.Submissions.Processor do
  @moduledoc "The production generation pipeline, independent of HTTP and job execution."

  require Logger
  alias DragNStamp.{Repo, Submissions, Timestamp}
  alias DragNStamp.SEO.{PagePath, VideoMetadata}
  alias DragNStamp.Submissions.PublishWorker
  alias DragNStamp.Timestamps.{CaptionFallback, CostEstimator, GeminiClient, Prompts}

  @doc "External IO can be injected with functions for deterministic production-path evaluations."
  def process(timestamp, opts \\ [])

  def process(%Timestamp{processing_status: :ready} = timestamp, _opts), do: {:ok, timestamp}

  def process(%Timestamp{} = timestamp, opts) do
    api_key = Keyword.get_lazy(opts, :api_key, fn -> System.get_env("GEMINI_API_KEY") end)

    if api_key in [nil, ""] do
      {:error,
       failure(:missing_api_key, "StampBot's Gemini API credentials are unavailable.", false)}
    else
      with {:ok, timestamp} <- generate_or_resume(timestamp, api_key, opts) do
        distill_and_finish(timestamp, api_key, opts)
      end
    end
  end

  @doc "The initial baseline retains the existing 20-minute routing policy."
  def route(seconds) when is_integer(seconds) and seconds > 0 and seconds <= 1_200, do: :video
  def route(_seconds), do: :captions

  # Content is a durable checkpoint. A worker restart after generation resumes
  # distillation without paying to analyze the video again.
  defp generate_or_resume(%Timestamp{content: content} = timestamp, _key, _opts)
       when is_binary(content) and content != "",
       do: {:ok, timestamp}

  defp generate_or_resume(timestamp, key, opts) do
    timestamp =
      Submissions.update!(timestamp, %{processing_phase: "acquiring", processing_error: nil})

    metadata_fun = Keyword.get(opts, :metadata_fun, &metadata/1)

    timestamp =
      case metadata_fun.(timestamp) do
        {:ok, updated} -> updated
        {:error, _reason} -> timestamp
      end

    timestamp = Submissions.update!(timestamp, %{processing_phase: "generating"})

    case route(timestamp.video_duration_seconds) do
      :video ->
        generate_video(timestamp, key, opts)

      :captions ->
        trigger =
          if is_integer(timestamp.video_duration_seconds),
            do: "length_gate",
            else: "duration_unknown"

        generate_captions(timestamp, key, opts, trigger, nil)
    end
  end

  defp generate_video(timestamp, key, opts) do
    video_fun = Keyword.get(opts, :video_fun, &GeminiClient.timestamps_detailed_with_retry/4)

    result =
      video_fun.(Prompts.video(timestamp.channel_name), key, timestamp.url,
        max_seconds: timestamp.video_duration_seconds,
        generation_config: %{"mediaResolution" => "MEDIA_RESOLUTION_LOW"}
      )

    case result do
      {:ok, result} ->
        checkpoint(
          timestamp,
          result.content,
          result.model_version || result.model,
          CostEstimator.estimate_usd(result),
          timestamp.video_duration_seconds
        )

      {:error, reason} ->
        generate_captions(timestamp, key, opts, "vlm_failure", reason)
    end
  end

  defp generate_captions(timestamp, key, opts, trigger, video_error) do
    caption_fun = Keyword.get(opts, :caption_fun, &CaptionFallback.process/4)

    result =
      caption_fun.(timestamp.channel_name, timestamp.url, key,
        trigger: trigger,
        max_seconds: timestamp.video_duration_seconds
      )

    case result do
      {:ok, content, meta} ->
        meta = put_video_error(meta, video_error)
        timestamp = record_caption_attempt(timestamp, meta)
        bound = timestamp.video_duration_seconds || meta["output_bound_seconds"]

        checkpoint(
          timestamp,
          content,
          meta["model"],
          CostEstimator.parse(meta["estimated_cost_usd"]),
          bound
        )

      {:error, reason, message, meta} ->
        meta = put_video_error(meta, video_error)
        record_caption_attempt(timestamp, meta)

        {:error,
         failure(
           reason,
           message,
           meta["retryable"] == true or retryable?(reason) or retryable?(video_error)
         )}
    end
  end

  defp checkpoint(timestamp, content, model, cost, bound) do
    context =
      (timestamp.processing_context || %{})
      |> Map.put("generation_model", model)
      |> Map.put("output_bound_seconds", bound)

    updated =
      Submissions.update!(timestamp, %{
        content: content,
        estimated_cost_usd: cost,
        processing_phase: "distilling",
        processing_context: context
      })

    {:ok, updated}
  end

  defp distill_and_finish(timestamp, key, opts) do
    timestamp = Submissions.update!(timestamp, %{processing_phase: "distilling"})
    text_fun = Keyword.get(opts, :text_fun, &GeminiClient.text_only_detailed/3)

    bound =
      timestamp.video_duration_seconds ||
        (timestamp.processing_context || %{})["output_bound_seconds"]

    case text_fun.(Prompts.distillation(timestamp.content), key, max_seconds: bound) do
      {:ok, result} ->
        finish(timestamp, result.content, CostEstimator.estimate_usd(result), opts)

      {:error, reason} ->
        # Keep a validated generation available if cosmetic distillation cannot
        # complete. Record the degraded outcome for the baseline and operators.
        context = Map.put(timestamp.processing_context || %{}, "distillation_failed", true)
        timestamp = Submissions.update!(timestamp, %{processing_context: context})
        Logger.warning("Submission #{timestamp.id} distillation failed: #{inspect(reason)}")
        finish(timestamp, nil, nil, opts)
    end
  end

  defp finish(timestamp, distilled, cost, opts) do
    result =
      Repo.transaction(fn ->
        updated =
          timestamp
          |> Timestamp.changeset(%{
            content: sign(timestamp.content, timestamp),
            distilled_content: if(is_binary(distilled), do: sign(distilled, timestamp)),
            estimated_cost_usd: CostEstimator.add(timestamp.estimated_cost_usd, cost),
            processing_status: :ready,
            processing_phase: "ready",
            processing_error: nil
          })
          |> Repo.update!()

        if Keyword.get(opts, :publish, true) and is_binary(distilled) do
          %{timestamp_id: timestamp.id} |> PublishWorker.new() |> Oban.insert!()
        end

        updated
      end)

    case result do
      {:ok, updated} ->
        Submissions.broadcast(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, failure(:persistence_failed, inspect(reason), true)}
    end
  end

  defp sign(content, timestamp) do
    slug = timestamp |> PagePath.filename() |> Path.rootname()
    String.trim_trailing(content) <> "\n\nTimestamps by StampBot 🤖\n(#{slug})"
  end

  defp record_caption_attempt(timestamp, meta) do
    context = timestamp.processing_context || %{}
    attempts = Enum.take([meta | Map.get(context, "caption_attempts", [])], 5)

    context =
      context
      |> Map.put("caption_attempts", attempts)
      |> Map.put("captions_summary", %{
        "last_result" => meta["result"],
        "last_reason" => meta["failure_reason"] || meta["reason"],
        "last_attempt_at" => meta["at"]
      })

    Submissions.update!(timestamp, %{processing_context: context})
  end

  defp put_video_error(meta, nil), do: meta

  defp put_video_error(meta, error),
    do: Map.put(meta, "vlm_error", inspect(error, limit: 20, printable_limit: 2_000))

  defp metadata(timestamp) do
    if Application.get_env(:drag_n_stamp, :fetch_video_metadata_on_ingest, true) do
      timestamp =
        case VideoMetadata.ensure_metadata(timestamp) do
          {:ok, updated} -> updated
          {:error, _} -> timestamp
        end

      if is_nil(timestamp.video_duration_seconds) do
        with {:ok, id} <- VideoMetadata.extract_video_id(timestamp.url),
             {:ok, seconds} when is_integer(seconds) and seconds > 0 <-
               VideoMetadata.fetch_duration_seconds(id) do
          {:ok, Submissions.update!(timestamp, %{video_duration_seconds: seconds})}
        else
          _ -> {:ok, timestamp}
        end
      else
        {:ok, timestamp}
      end
    else
      {:ok, timestamp}
    end
  end

  defp failure(reason, message, retryable),
    do: %{reason: reason, message: message, retryable: retryable}

  defp retryable?(reason) when reason in [:youtube_network_error, :youtube_rate_limited], do: true
  defp retryable?(%{kind: :transport}), do: true

  defp retryable?(%{kind: :http, status: status}),
    do: status in [408, 409, 425, 429] or status >= 500

  defp retryable?(_), do: false
end
