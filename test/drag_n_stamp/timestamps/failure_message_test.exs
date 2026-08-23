defmodule DragNStamp.Timestamps.FailureMessageTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.FailureMessage
  alias DragNStamp.Timestamp

  test "shows the friendly caption failure stored on the record" do
    error =
      "[captions_fallback_failed] YouTube temporarily rate-limited caption requests. (length=59m)"

    assert %{
             category: "caption_pipeline",
             summary: "YouTube temporarily rate-limited caption requests. (length=59m)",
             guidance: guidance
           } = FailureMessage.from_error(error)

    assert guidance =~ "not scheduled an automatic retry"
  end

  test "maps combined Gemini and caption failures without exposing provider payloads" do
    error =
      ~s([gemini_vlm_failed] %{kind: :http, status: 429, body_preview: "internal"} | captions=youtube_auth_failed)

    details = FailureMessage.from_error(error)

    assert details.category == "gemini_and_youtube_auth_failed"
    assert details.summary =~ "Direct video analysis failed"
    assert details.summary =~ "caption access credentials"
    refute details.summary =~ "body_preview"
  end

  test "uses recorded caption context to replace an older generic fetch error" do
    timestamp = %Timestamp{
      processing_error:
        "[captions_fallback_failed] We hit an issue fetching captions from YouTube. It's logged for future analysis. (length=59m)",
      processing_context: %{
        "caption_attempts" => [%{"failure_reason" => "youtube_rate_limited"}]
      }
    }

    details = FailureMessage.for_timestamp(timestamp)

    assert details.category == "caption_youtube_rate_limited"
    assert details.summary =~ "rate-limited"
    refute details.summary =~ "issue fetching captions"
  end

  test "is honest when no classified error was stored" do
    details = FailureMessage.from_error("unexpected internal value")

    assert details.category == "unclassified"
    assert details.summary =~ "unclassified service error"
    assert details.guidance =~ "not scheduled an automatic retry"
  end
end
