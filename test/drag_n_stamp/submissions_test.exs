defmodule DragNStamp.SubmissionsTest do
  use DragNStamp.DataCase, async: false
  use Oban.Testing, repo: DragNStamp.Repo

  alias DragNStamp.{Submissions, Timestamp}
  alias DragNStamp.Submissions.{Processor, PublishWorker, Worker}
  alias DragNStamp.Timestamps.GeminiClient.Result

  @video_id "abc123xyz89"
  @url "https://www.youtube.com/watch?v=#{@video_id}"

  setup do
    previous = Application.get_env(:drag_n_stamp, :submission_processor_options)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:drag_n_stamp, :submission_processor_options),
        else: Application.put_env(:drag_n_stamp, :submission_processor_options, previous)
    end)

    :ok
  end

  test "canonical variants share a record/job, while a different video gets its own job" do
    {:ok, first, :created} = Submissions.submit(@url <> "&list=playlist&t=20")
    {:ok, same, :existing} = Submissions.submit("https://youtu.be/#{@video_id}?si=tracking")
    {:ok, other, :created} = Submissions.submit("https://www.youtube.com/shorts/def456xyz89")

    assert same.id == first.id
    assert other.id != first.id
    assert Repo.aggregate(Timestamp, :count) == 2
    assert length(all_enqueued(worker: Worker)) == 2
  end

  test "ready legacy results are reused by video identity" do
    timestamp =
      insert_timestamp(%{
        url: @url <> "&feature=share",
        video_id: @video_id,
        processing_status: :ready,
        content: "0:00 Intro"
      })

    {:ok, cached, :existing} = Submissions.submit("https://youtu.be/#{@video_id}")
    assert cached.id == timestamp.id
    refute_enqueued(worker: Worker)
    assert Submissions.response(cached).status == "success"
  end

  test "status distinguishes a known cost subtotal from complete accounting" do
    timestamp =
      insert_timestamp(%{
        processing_status: :ready,
        content: "0:00 Intro",
        estimated_cost_usd: Decimal.new("0.01"),
        processing_context: %{"cost_complete" => false, "unknown_cost_requests" => 2}
      })

    assert %{estimated_cost_usd: "0.01", cost_complete: false, unknown_cost_requests: 2} =
             Submissions.response(timestamp)

    assert %{cost_complete: nil, unknown_cost_requests: nil} =
             Submissions.response(%{timestamp | processing_context: nil})
  end

  test "failure to insert a job rolls the submission back too" do
    # A real database constraint injects failure at the second write in the
    # acceptance transaction. The surrounding sandbox rolls back the DDL.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE oban_jobs ADD CONSTRAINT reject_test_worker CHECK (worker <> 'DragNStamp.Submissions.Worker')",
      []
    )

    assert_raise Ecto.ConstraintError, fn -> Submissions.submit(@url) end
    assert Repo.aggregate(Timestamp, :count) == 0
    refute_enqueued(worker: Worker)
  end

  test "manual retry is claimed once and clears obsolete candidates" do
    timestamp = insert_timestamp(%{processing_status: :ready, content: "0:00 UNWATCHED"})
    assert {:ok, queued} = Submissions.retry(timestamp)
    assert queued.processing_context["manual_retry_used"]
    assert queued.content == nil
    assert {:error, :retry_not_allowed} = Submissions.retry(timestamp)
    assert length(all_enqueued(worker: Worker)) == 1
  end

  test "resubmission cannot disappear into a previous job awaiting cancellation" do
    {:ok, timestamp, :created} = Submissions.submit(@url)
    job = Repo.get_by!(Oban.Job, args: %{"timestamp_id" => timestamp.id})

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing", attempt: 1]
    )

    Submissions.update!(timestamp, %{processing_status: :failed, processing_phase: "failed"})

    assert {:error, :retry_in_flight} = Submissions.submit(@url)
    assert Repo.get!(Timestamp, timestamp.id).processing_status == :failed

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "cancelled"])
    assert {:ok, queued, :existing} = Submissions.submit(@url)
    assert queued.processing_status == :processing
    assert length(all_enqueued(worker: Worker)) == 1
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "a worker resumes saved candidates without reacquiring or regenerating the video" do
    timestamp =
      insert_timestamp(%{
        content: "0:00 Opening\n2:00 Conclusion",
        video_duration_seconds: 180,
        processing_phase: "distilling"
      })

    parent = self()

    opts = [
      api_key: "fixture-key",
      publish: false,
      metadata_fun: fn _ -> flunk("metadata should not be fetched after checkpoint") end,
      video_fun: fn _, _, _, _ -> flunk("generation should not repeat") end,
      caption_fun: fn _, _, _, _ -> flunk("captions should not repeat") end,
      text_fun: fn _prompt, _key, options ->
        send(parent, {:distillation_bound, options[:max_seconds]})
        {:ok, result("0:00 Opening\n2:00 Conclusion")}
      end
    ]

    assert {:ok, ready} = Processor.process(timestamp, opts)
    assert_receive {:distillation_bound, 180}
    assert ready.processing_status == :ready
    assert ready.distilled_content =~ "2:00 Conclusion"
    assert Repo.get!(Timestamp, timestamp.id).processing_phase == "ready"
    refute_enqueued(worker: PublishWorker)
  end

  test "completion remains available while automatic publication is disabled" do
    previous = Application.get_env(:drag_n_stamp, :publication_mode)
    Application.put_env(:drag_n_stamp, :publication_mode, :manual)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :publication_mode, previous) end)
    timestamp = insert_timestamp(%{content: "0:00 Opening", video_duration_seconds: 30})
    opts = [api_key: "fixture-key", text_fun: fn _, _, _ -> {:ok, result("0:00 Opening")} end]
    assert {:ok, ready} = Processor.process(timestamp, opts)
    assert ready.processing_status == :ready
    refute_enqueued(worker: PublishWorker)
  end

  test "completion and an explicitly enabled automatic publishing job persist together" do
    previous = Application.get_env(:drag_n_stamp, :publication_mode)
    Application.put_env(:drag_n_stamp, :publication_mode, :automatic)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :publication_mode, previous) end)
    timestamp = insert_timestamp(%{content: "0:00 Opening", video_duration_seconds: 30})
    opts = [api_key: "fixture-key", text_fun: fn _, _, _ -> {:ok, result("0:00 Opening")} end]
    assert {:ok, ready} = Processor.process(timestamp, opts)
    assert ready.processing_status == :ready
    assert_enqueued(worker: PublishWorker, args: %{timestamp_id: timestamp.id})
    assert PublishWorker.new(%{timestamp_id: timestamp.id}).changes.max_attempts == 1
  end

  test "transient provider failure retries the persisted job and finishes on recovery" do
    {:ok, timestamp, :created} = Submissions.submit(@url)

    Application.put_env(:drag_n_stamp, :submission_processor_options,
      api_key: "fixture-key",
      publish: false,
      metadata_fun: fn ts -> {:ok, ts} end,
      caption_fun: fn _, _, _, _ ->
        {:error, :youtube_rate_limited, "YouTube temporarily rate-limited captions.", %{}}
      end
    )

    assert %{failure: 1} = Oban.drain_queue(queue: :submissions)
    assert Repo.get!(Timestamp, timestamp.id).processing_phase == "retrying"
    assert Repo.get_by!(Oban.Job, worker: "DragNStamp.Submissions.Worker").state == "retryable"

    Application.put_env(:drag_n_stamp, :submission_processor_options,
      api_key: "fixture-key",
      publish: false,
      metadata_fun: fn ts -> {:ok, ts} end,
      caption_fun: fn _, _, _, _ -> {:ok, "0:00 Opening", %{"output_bound_seconds" => 30}} end,
      text_fun: fn _, _, options ->
        assert options[:max_seconds] == 30
        {:ok, result("0:00 Opening")}
      end
    )

    assert %{success: 1} = Oban.drain_queue(queue: :submissions, with_scheduled: true)
    assert Repo.get!(Timestamp, timestamp.id).processing_status == :ready
  end

  test "automatic publishing includes a retained full result when optional distillation fails" do
    previous = Application.get_env(:drag_n_stamp, :publication_mode)
    Application.put_env(:drag_n_stamp, :publication_mode, :automatic)
    on_exit(fn -> Application.put_env(:drag_n_stamp, :publication_mode, previous) end)

    timestamp =
      insert_timestamp(%{content: "0:00 Opening\n42:57 Ending", video_duration_seconds: 2595})

    assert {:ok, ready} =
             Processor.process(timestamp,
               api_key: "fixture-key",
               text_fun: fn _, _, _ -> {:error, %{kind: :invalid_model_output}} end
             )

    assert ready.processing_status == :ready
    assert is_nil(ready.distilled_content)
    assert ready.content =~ "42:57 Ending"

    assert_enqueued(
      worker: PublishWorker,
      args: %{timestamp_id: timestamp.id, publication_source: "automatic"}
    )
  end

  test "terminal source failures stop retrying and remain visible" do
    {:ok, timestamp, :created} = Submissions.submit(@url)

    Application.put_env(:drag_n_stamp, :submission_processor_options,
      api_key: "fixture-key",
      publish: false,
      metadata_fun: fn ts -> {:ok, ts} end,
      caption_fun: fn _, _, _, _ ->
        {:error, :video_unavailable, "The video is unavailable.", %{}}
      end
    )

    assert %{cancelled: 1} = Oban.drain_queue(queue: :submissions)
    failed = Repo.get!(Timestamp, timestamp.id)
    assert failed.processing_status == :failed
    assert Submissions.response(failed).message == "The video is unavailable."
  end

  test "reconciliation queues legacy placeholders and resolves exhausted crashed jobs" do
    legacy =
      insert_timestamp(%{
        url: "https://www.youtube.com/watch?v=legacyXYZ89",
        video_id: "legacyXYZ89"
      })

    {:ok, crashed, :created} = Submissions.submit(@url)
    job = Repo.get_by!(Oban.Job, args: %{"timestamp_id" => crashed.id})

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "discarded", attempt: 3]
    )

    assert :ok = Submissions.recover()
    assert :ok = Submissions.recover()
    assert_enqueued(worker: Worker, args: %{timestamp_id: legacy.id})
    assert length(all_enqueued(worker: Worker)) == 1
    assert Repo.get!(Timestamp, crashed.id).processing_status == :failed
  end

  test "rescue threshold cannot duplicate a healthy worker before its timeout" do
    opts = Application.fetch_env!(:drag_n_stamp, Oban)
    rescue_after = opts[:lifeline][:rescue_after] |> Oban.Period.to_milliseconds()
    assert rescue_after > Worker.timeout(%Oban.Job{})
  end

  defp insert_timestamp(attrs) do
    defaults = %{
      url: @url,
      video_id: @video_id,
      channel_name: "Test",
      processing_status: :processing
    }

    %Timestamp{} |> Timestamp.changeset(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  defp result(content) do
    %Result{
      content: content,
      timestamps: [%{seconds: 0, title: "Opening"}],
      model: "fixture",
      duration_ms: 0,
      attempts: 1
    }
  end
end
