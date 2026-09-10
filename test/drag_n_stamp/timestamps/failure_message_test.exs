defmodule DragNStamp.Timestamps.FailureMessageTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.FailureMessage
  alias DragNStamp.Timestamp

  test "legacy out-of-excerpt failures get accurate copy through the public API" do
    timestamp = %Timestamp{
      id: 593,
      processing_status: :failed,
      processing_context: %{
        "last_failure" => "timestamp_extraction_failed",
        "public_error" =>
          "Gemini responded without clear timestamps. We've saved the output for debugging.",
        "caption_attempts" => [%{"detail" => "{:timestamp_outside_excerpt, 1019, 0, 893}"}]
      }
    }

    details = FailureMessage.for_timestamp(timestamp)
    assert details.category == "timestamp_outside_excerpt"
    assert details.summary =~ "outside the excerpt"
    refute details.summary =~ "saved the output"
    assert DragNStamp.Submissions.response(timestamp).message == details.summary
  end

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

  test "uses current copy for a classified error stored with outdated guidance" do
    timestamp = %Timestamp{
      processing_error:
        "[captions_fallback_failed] YouTube rejected the server's caption access credentials. This video has been saved while we refresh access. (length=59m)",
      processing_context: %{
        "caption_attempts" => [%{"failure_reason" => "youtube_auth_failed"}]
      }
    }

    details = FailureMessage.for_timestamp(timestamp)

    assert details.category == "caption_youtube_auth_failed"
    assert details.summary =~ "server-side access issue"
    refute details.summary =~ "while we refresh access"
  end

  test "is honest when no classified error was stored" do
    details = FailureMessage.from_error("unexpected internal value")

    assert details.category == "unclassified"
    assert details.summary =~ "unclassified service error"
    assert details.guidance =~ "not scheduled an automatic retry"
  end
end
