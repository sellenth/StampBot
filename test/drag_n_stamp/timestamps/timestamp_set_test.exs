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

  test "decoding sorts chapter pairs without losing entries or changing their times and titles" do
    raw = [
      %{"seconds" => 772, "title" => "Later discussion"},
      %{"seconds" => 101, "title" => "Earlier discussion"},
      %{"seconds" => 0, "title" => "Opening"}
    ]

    assert {:ok, content, timestamps} =
             TimestampSet.decode(Jason.encode!(%{timestamps: raw}),
               min_seconds: 0,
               max_seconds: 893
             )

    assert timestamps == [
             %{seconds: 0, title: "Opening"},
             %{seconds: 101, title: "Earlier discussion"},
             %{seconds: 772, title: "Later discussion"}
           ]

    assert content == "0:00 Opening\n1:41 Earlier discussion\n12:52 Later discussion"

    assert {:ok, ^timestamps} =
             TimestampSet.validate(Enum.sort_by(raw, & &1["seconds"]), max_seconds: 893)
  end

  test "sorting does not repair duplicate times, clock resets, or discard invalid entries" do
    decode = fn seconds, opts ->
      raw = Enum.map(seconds, &%{seconds: &1, title: "Evidence at this position"})
      TimestampSet.decode(Jason.encode!(%{timestamps: raw}), opts)
    end

    assert {:error, {:timestamps_not_strictly_increasing, 101, 101}} =
             decode.([772, 101, 101], max_seconds: 893)

    assert {:error, {:timestamp_out_of_bounds, 1019, 893}} =
             decode.([772, 101, 1019], min_seconds: 0, max_seconds: 893)

    assert {:error, {:timestamp_outside_excerpt, 101, 900, 1793}} =
             decode.([1672, 101], min_seconds: 900, max_seconds: 1793)

    assert {:error, {:invalid_timestamp, 1, :invalid_fields}} =
             decode.([772, "101"], max_seconds: 893)
  end
end
