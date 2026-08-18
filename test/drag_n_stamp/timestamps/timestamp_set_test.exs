defmodule DragNStamp.Timestamps.TimestampSetTest do
  use ExUnit.Case, async: true

  alias DragNStamp.Timestamps.TimestampSet

  test "decodes, validates, and renders structured timestamps" do
    response =
      Jason.encode!(%{
        "timestamps" => [
          %{"seconds" => 0, "title" => "Opening setup and the central challenge begins"},
          %{"seconds" => 65, "title" => "The first surprising result changes the plan"},
          %{"seconds" => 3_661, "title" => "Final lessons and a look back at everything"}
        ]
      })

    assert {:ok, rendered, timestamps} = TimestampSet.decode(response, max_seconds: 4_000)
    assert length(timestamps) == 3

    assert rendered ==
             "0:00 Opening setup and the central challenge begins\n" <>
               "1:05 The first surprising result changes the plan\n" <>
               "1:01:01 Final lessons and a look back at everything"
  end

  test "rejects empty, duplicate, unordered, and out-of-bounds timestamps" do
    assert {:error, :timestamps_empty} = TimestampSet.validate([])

    assert {:error, {:timestamps_not_strictly_increasing, 10, 10}} =
             TimestampSet.validate([
               %{"seconds" => 10, "title" => "First"},
               %{"seconds" => 10, "title" => "Duplicate"}
             ])

    assert {:error, {:timestamps_not_strictly_increasing, 20, 10}} =
             TimestampSet.validate([
               %{"seconds" => 20, "title" => "Later"},
               %{"seconds" => 10, "title" => "Earlier"}
             ])

    assert {:error, {:timestamp_out_of_bounds, 121, 120}} =
             TimestampSet.validate(
               [%{"seconds" => 121, "title" => "Past the video"}],
               max_seconds: 120
             )
  end

  test "rejects malformed JSON and malformed timestamp fields" do
    assert {:error, {:invalid_json, _position}} = TimestampSet.decode("not-json")

    assert {:error, {:invalid_timestamp, 0, :invalid_fields}} =
             TimestampSet.validate([%{"seconds" => "0", "title" => "Wrong type"}])
  end
end
