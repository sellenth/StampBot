defmodule Mix.Tasks.Stampbot.ExportEvalCohortTest do
  use DragNStamp.DataCase, async: true
  alias DragNStamp.Timestamp
  alias Mix.Tasks.Stampbot.ExportEvalCohort, as: Export

  test "stable video identity split survives duplicates, input reordering, and cohort growth" do
    original = for id <- 1..120, do: row(id)
    first = Export.build_manifest(original, per_stratum: 1_000)

    second =
      Export.build_manifest(Enum.reverse(original ++ [row(1, %{id: 900})]), per_stratum: 1_000)

    assignments = fn report -> Map.new(report.videos, &{&1.video_id, &1.split}) end

    assert assignments.(first) == assignments.(second)
    assert length(second.videos) == 120
    assert Enum.any?(first.videos, &(&1.split == "held_out"))
    assert Enum.any?(first.videos, &(&1.split == "tuning"))
    assert Enum.find(second.videos, &(&1.video_id == video_id(1))).matching_submission_count == 2
  end

  test "samples each historical outcome, duration, and recorded language stratum deterministically" do
    rows =
      for id <- 1..30 do
        row(id, %{duration_seconds: if(id <= 15, do: 120, else: 7_200)})
      end

    first = Export.build_manifest(rows, per_stratum: 3)
    second = Export.build_manifest(Enum.reverse(rows), per_stratum: 3)
    assert length(first.videos) == 6
    assert Enum.map(first.videos, & &1.video_id) == Enum.map(second.videos, & &1.video_id)
    assert Enum.all?(first.coverage, &(&1.candidate_videos == 15 and &1.selected_videos == 3))
    assert first.semantic_quality == "UNREVIEWED"
  end

  test "exports only allowlisted metadata and marks unverifiable language and errors unknown" do
    report =
      Export.build_manifest([
        row(1, %{
          submitter_username: "private-username",
          content: "PRIVATE TRANSCRIPT",
          processing_error: "SECRET RAW ERROR",
          processing_context: %{"prompt" => "PRIVATE PROMPT"},
          caption_failure: "RAW PROVIDER ERROR token=secret",
          caption_language: "=IMPORTXML(secret)"
        })
      ])

    encoded = Jason.encode!(report)
    refute encoded =~ "private-username"
    refute encoded =~ "PRIVATE"
    refute encoded =~ "SECRET"
    refute encoded =~ "token=secret"
    refute encoded =~ "IMPORTXML"
    assert hd(report.videos).caption_language == "unknown"
    assert hd(report.videos).failure_category == "unknown"
    assert hd(report.videos).source_availability == "unreviewed"
  end

  test "rare failure categories receive their own sample allocation" do
    rows = Enum.map(1..20, &row/1) ++ [row(21, %{caption_failure: "youtube_rate_limited"})]
    report = Export.build_manifest(rows, per_stratum: 1)
    assert length(report.videos) == 2
    assert Enum.any?(report.videos, &(&1.failure_category == "youtube_rate_limited"))
    assert Enum.any?(report.videos, &(&1.failure_category == "captions_unavailable"))
  end

  test "separates failed, sentinel, degraded, recovered fallback, and healthy outcomes" do
    rows = [
      row(1),
      row(2, %{processing_status: :ready, unwatched: true}),
      row(3, %{processing_status: :ready, distillation_failed: true}),
      row(4, %{processing_status: :ready, has_distilled: false}),
      row(5, %{processing_status: :ready, caption_trigger: "vlm_failure"}),
      row(6, %{processing_status: :ready})
    ]

    report = Export.build_manifest(rows)

    assert MapSet.new(Enum.map(report.videos, & &1.outcome)) ==
             MapSet.new(
               ~w(failed unusable_unwatched distillation_failed primary_only video_fallback_recovered)
             )

    assert report.selection.invalid_or_ineligible_rows_omitted == 1
  end

  test "SQL selects actual failed/degraded rows without raw content or identity metadata" do
    insert_timestamp(1, %{processing_status: :failed, processing_error: "raw failure"})

    insert_timestamp(2, %{
      processing_status: :ready,
      content: "0:00 UNWATCHED",
      distilled_content: "0:00 UNWATCHED"
    })

    insert_timestamp(3, %{
      processing_status: :ready,
      content: "0:00 Opening",
      distilled_content: "0:00 Opening"
    })

    insert_timestamp(4, %{processing_status: :processing})

    insert_timestamp(5, %{
      processing_status: :ready,
      content: "0:00 Opening",
      distilled_content: nil
    })

    rows = Repo.all(Export.candidate_query(100))
    assert Enum.sort(Enum.map(rows, & &1.video_id)) == Enum.map([1, 2, 5], &video_id/1)
    refute Enum.any?(rows, &Map.has_key?(&1, :content))
    refute Enum.any?(rows, &Map.has_key?(&1, :processing_error))
    refute Enum.any?(rows, &Map.has_key?(&1, :submitter_username))
  end

  test "review sheet quotes cells and neutralizes spreadsheet formulas" do
    csv = Export.review_csv([%{cohort_id: "safe", notes: "=1+1", reviewer: "Name, \"Quoted\""}])
    assert csv =~ "\"'=1+1\""
    assert csv =~ "\"Name, \"\"Quoted\"\"\""
    assert csv =~ "factual_support_0_to_2"
    assert csv =~ "acquisition_outcome"
  end

  test "writes private artifacts once and refuses replacing a frozen cohort" do
    path = Path.join(System.tmp_dir!(), "stampbot-cohort-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    report = Export.build_manifest([row(1)])
    assert :ok = Export.write_artifacts!(report, path)
    assert File.exists?(Path.join(path, "manifest.json"))
    assert File.exists?(Path.join(path, "review.csv"))
    assert Bitwise.band(File.stat!(Path.join(path, "manifest.json")).mode, 0o777) == 0o600
    assert_raise File.Error, fn -> Export.write_artifacts!(report, path) end
  end

  test "invalid identities are omitted without leaking their raw URLs" do
    report =
      Export.build_manifest([row(1, %{video_id: nil, url: "https://private.example/secret"})])

    assert report.videos == []
    assert report.selection.invalid_or_ineligible_rows_omitted == 1
    refute Jason.encode!(report) =~ "private.example"
  end

  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        video_id: video_id(id),
        url: "https://www.youtube.com/watch?v=#{video_id(id)}",
        duration_seconds: 120,
        processing_status: :failed,
        has_primary: true,
        has_distilled: true,
        distillation_failed: false,
        unwatched: false,
        caption_failure: "captions_unavailable",
        caption_trigger: nil,
        caption_language: "en",
        updated_at: ~N[2026-09-09 12:00:00]
      },
      overrides
    )
  end

  defp video_id(id), do: id |> Integer.to_string() |> String.pad_leading(11, "0")

  defp insert_timestamp(id, attrs) do
    %Timestamp{}
    |> Timestamp.changeset(
      Map.merge(
        %{
          url: "https://www.youtube.com/watch?v=#{video_id(id)}",
          video_id: video_id(id),
          channel_name: "Synthetic test"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
