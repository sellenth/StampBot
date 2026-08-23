defmodule DragNStamp.Timestamps.FailureMessage do
  @moduledoc """
  Converts stored processing failures into safe, useful public copy.

  Raw provider payloads stay in logs and processing context. The UI receives a
  stable explanation and honest retry guidance instead of promising an
  automatic retry that the application does not schedule.
  """

  alias DragNStamp.Timestamp
  alias DragNStamp.Timestamps.CaptionFallback

  @generic_summary "Timestamp generation failed because of an unclassified service error. The technical reason was recorded for investigation."
  @generic_guidance "This may be temporary, but StampBot has not scheduled an automatic retry."

  @caption_reason_atoms %{
    "missing_api_key" => :missing_api_key,
    "video_id_not_found" => :video_id_not_found,
    "captions_unavailable" => :captions_unavailable,
    "captions_empty" => :captions_empty,
    "captions_fetch_failed" => :captions_fetch_failed,
    "caption_downloader_outdated" => :caption_downloader_outdated,
    "caption_downloader_unavailable" => :caption_downloader_unavailable,
    "caption_runtime_outdated" => :caption_runtime_outdated,
    "youtube_auth_failed" => :youtube_auth_failed,
    "youtube_rate_limited" => :youtube_rate_limited,
    "youtube_network_error" => :youtube_network_error,
    "video_unavailable" => :video_unavailable,
    "transcript_empty" => :transcript_empty,
    "gemini_error" => :gemini_error,
    "timestamp_extraction_failed" => :timestamp_extraction_failed,
    "no_timestamps" => :no_timestamps
  }

  @unlikely_retry_reasons ~w(captions_unavailable captions_empty video_unavailable transcript_empty)

  @type details :: %{summary: String.t(), guidance: String.t(), category: String.t()}

  @spec for_timestamp(Timestamp.t()) :: details()
  def for_timestamp(%Timestamp{processing_error: error, processing_context: context}) do
    from_error(error, latest_caption_reason(context))
  end

  @spec from_error(term()) :: details()
  def from_error(error), do: from_error(error, nil)

  defp from_error(error, caption_reason) when is_binary(error) do
    cond do
      String.starts_with?(error, "[captions_fallback_failed]") ->
        summary =
          caption_summary(strip_prefix(error, "[captions_fallback_failed]"), caption_reason)

        details(
          summary,
          caption_category(caption_reason),
          caption_guidance(caption_reason)
        )

      String.starts_with?(error, "[unsupported:video_too_long]") ->
        details(
          strip_prefix(error, "[unsupported:video_too_long]"),
          "video_too_long",
          "This limitation will not be fixed by retrying the same video."
        )

      String.starts_with?(error, "[gemini_vlm_failed]") ->
        gemini_fallback_details(error)

      String.contains?(error, "GEMINI_API_KEY") ->
        details(
          "StampBot's Gemini API credentials were unavailable when this submission ran.",
          "gemini_credentials",
          "This is a service configuration problem; retrying may work after access is restored."
        )

      true ->
        details(@generic_summary, "unclassified", @generic_guidance)
    end
  end

  defp from_error(_, _), do: details(@generic_summary, "unclassified", @generic_guidance)

  defp latest_caption_reason(context) when is_map(context) do
    context
    |> Map.get("caption_attempts", [])
    |> List.first()
    |> case do
      %{"failure_reason" => reason} when is_binary(reason) -> reason
      _ -> nil
    end
  end

  defp latest_caption_reason(_), do: nil

  defp caption_summary(stored_summary, reason) do
    atom = Map.get(@caption_reason_atoms, reason)

    if atom do
      CaptionFallback.failure_message(atom)
    else
      stored_summary
    end
  end

  defp caption_category(nil), do: "caption_pipeline"
  defp caption_category(reason), do: "caption_#{reason}"

  defp caption_guidance(reason) when reason in @unlikely_retry_reasons do
    "Retrying is unlikely to help unless the video's availability or captions change."
  end

  defp caption_guidance(_), do: @generic_guidance

  defp gemini_fallback_details(error) do
    case Regex.run(~r/captions=([a-z_]+)/, error) do
      [_, reason] ->
        atom = Map.get(@caption_reason_atoms, reason)

        summary =
          if atom do
            "Direct video analysis failed. " <> CaptionFallback.failure_message(atom)
          else
            "Direct video analysis and the caption fallback both failed. The technical reasons were recorded for investigation."
          end

        guidance =
          if reason in @unlikely_retry_reasons do
            "Retrying is unlikely to help unless the video's availability or captions change."
          else
            @generic_guidance
          end

        details(summary, "gemini_and_#{reason}", guidance)

      _ ->
        details(
          "Direct video analysis and the caption fallback both failed. The technical reasons were recorded for investigation.",
          "gemini_and_caption_fallback",
          @generic_guidance
        )
    end
  end

  defp strip_prefix(error, prefix) do
    error
    |> String.replace_prefix(prefix, "")
    |> String.trim()
    |> case do
      "" -> @generic_summary
      message -> message
    end
  end

  defp details(summary, category, guidance) do
    %{summary: summary, category: category, guidance: guidance}
  end
end
