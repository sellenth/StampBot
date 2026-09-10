defmodule DragNStamp.ProcessingAttempts do
  @moduledoc """
  Records production work without storing prompts, source media, response bodies, or credentials.

  Context is scoped to the executing process and restored after each span. Calls
  without a persisted submission context remain usable in standalone client tests.
  An untrappable process kill leaves a running row; a later attempt for that same
  job marks older unfinished work interrupted without inventing a duration or cost.
  """
  import Ecto.Query
  alias DragNStamp.{ProcessingAttempt, Repo}
  alias DragNStamp.Timestamps.CostEstimator

  @context_key {__MODULE__, :context}
  @context_fields ~w(timestamp_id reservation_id job_id job_attempt run_id parent_attempt_id stage
    chunk_index operation prompt_version)a
  @token_fields ~w(prompt_tokens output_tokens thinking_tokens cached_tokens total_tokens)a
  @failure_kinds ~w(transport http invalid_json_response invalid_model_output missing_candidates
    missing_candidate_text prompt_blocked unwatched incomplete_output work_budget_exceeded
    input_limit_exceeded missing_api_key video_id_not_found captions_unavailable captions_empty
    captions_fetch_failed caption_downloader_outdated caption_runtime_outdated caption_downloader_unavailable
    youtube_auth_failed youtube_rate_limited youtube_network_error video_unavailable transcript_empty
    gemini_error timestamp_extraction_failed no_timestamps timestamp_outside_excerpt timestamp_out_of_bounds
    timestamps_not_strictly_increasing persistence_failed
    caller_rate_limited video_cooldown daily_work_limit daily_budget_exceeded
    worker_exception worker_interrupted exception process_exit other)

  def context, do: Process.get(@context_key, %{})

  def with_context(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    previous = Process.get(@context_key)
    Process.put(@context_key, Map.merge(context(), Map.take(attrs, @context_fields)))

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@context_key),
        else: Process.put(@context_key, previous)
    end
  end

  def with_run(attrs, fun) when is_function(fun, 1) do
    attrs =
      Map.merge(attrs, %{
        run_id: Ecto.UUID.generate(),
        parent_attempt_id: nil,
        stage: "processing"
      })

    interrupt_previous_attempts(attrs)
    with_context(attrs, fn -> around(%{kind: :run, stage: "processing"}, fun) end)
  end

  def around(attrs, fun) when is_function(fun, 0), do: around(attrs, fn _ -> fun.() end)

  def around(attrs, fun) when is_map(attrs) and is_function(fun, 1) do
    handle = start(attrs)
    nested = Map.merge(attrs, %{parent_attempt_id: handle.id})

    with_context(nested, fn ->
      try do
        result = fun.(handle)
        finish(handle, result)
        result
      rescue
        error ->
          finish(handle, {:error, :exception})
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          finish(handle, {:error, :process_exit})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  def annotate(%{id: nil}, _attrs), do: :ok

  def annotate(%{id: id}, attrs) do
    Repo.get!(ProcessingAttempt, id)
    |> ProcessingAttempt.changeset(attrs)
    |> Repo.update!()

    :ok
  end

  def response(handle, attrs, usage) do
    estimate = CostEstimator.estimate_usage_usd(attrs[:model], usage)

    usage_status =
      cond do
        map_size(usage) == 0 -> :not_reported
        is_integer(usage[:prompt_tokens]) and is_integer(usage[:output_tokens]) -> :reported
        true -> :partial
      end

    fields =
      attrs
      |> Map.take([:model, :model_version, :provider_request_id, :finish_reason, :http_status])
      |> Map.merge(Map.take(usage, @token_fields))
      |> Map.merge(%{
        usage_status: usage_status,
        cost_status: if(is_nil(estimate), do: :unknown, else: :estimated),
        estimated_cost_usd: estimate
      })

    annotate(handle, fields)
    estimate
  end

  def for_timestamp(timestamp_id) do
    Repo.all(from a in ProcessingAttempt, where: a.timestamp_id == ^timestamp_id, order_by: a.id)
  end

  def cost_summary(timestamp_id) do
    {cost, count, unknown} =
      Repo.one(
        from a in ProcessingAttempt,
          where: a.timestamp_id == ^timestamp_id and a.kind == :request and a.dispatched,
          select:
            {sum(a.estimated_cost_usd), count(a.id),
             filter(count(a.id), a.cost_status == :unknown)}
      )

    %{
      known_cost_usd: cost,
      request_count: count,
      unknown_request_count: unknown
    }
  end

  @doc "Returns a bounded failure category, never the source error's message or payload."
  def failure_kind(%{kind: :invalid_model_output, reason: reason}) do
    case failure_kind(reason) do
      value
      when value in [
             "unwatched",
             "incomplete_output",
             "prompt_blocked",
             "timestamp_outside_excerpt",
             "timestamp_out_of_bounds",
             "timestamps_not_strictly_increasing"
           ] ->
        value

      _ ->
        "invalid_model_output"
    end
  end

  def failure_kind(%{kind: kind}), do: failure_kind(kind)
  def failure_kind(%{reason: reason}), do: failure_kind(reason)
  def failure_kind(reason) when is_tuple(reason), do: reason |> elem(0) |> failure_kind()

  def failure_kind(reason) when is_atom(reason) or is_binary(reason) do
    value = to_string(reason)
    if value in @failure_kinds, do: value, else: "other"
  end

  def failure_kind(_reason), do: "other"

  defp start(attrs) do
    started_mono = System.monotonic_time(:millisecond)
    ctx = context()

    attrs =
      ctx
      |> Map.merge(attrs)
      |> Map.put(:started_at, DateTime.utc_now())
      |> Map.put(:status, :running)
      |> Map.put_new(
        :cost_status,
        if(attrs[:kind] == :request, do: :unknown, else: :not_applicable)
      )
      |> normalize_identifiers()

    id =
      if is_integer(ctx[:timestamp_id]) do
        %ProcessingAttempt{}
        |> ProcessingAttempt.changeset(attrs)
        |> Repo.insert!()
        |> Map.fetch!(:id)
      end

    %{id: id, started_mono: started_mono, attributes: attrs}
  end

  defp finish(handle, result) do
    {status, failure} = outcome(result)
    duration = max(System.monotonic_time(:millisecond) - handle.started_mono, 0)

    attrs = %{
      status: status,
      failure_kind: failure,
      finished_at: DateTime.utc_now(),
      duration_ms: duration
    }

    annotate(handle, attrs)

    :telemetry.execute(
      [:drag_n_stamp, :processing, :attempt],
      %{duration_ms: duration, count: 1},
      %{
        kind: handle.attributes.kind,
        stage: handle.attributes.stage,
        provider: handle.attributes[:provider] || "local",
        status: status,
        failure_kind: failure || "none"
      }
    )
  end

  defp outcome({:error, reason}), do: {:failed, failure_kind(reason)}
  defp outcome({:error, reason, _}), do: {:failed, failure_kind(reason)}
  defp outcome({:error, reason, _, _}), do: {:failed, failure_kind(reason)}
  defp outcome({:error, reason, _, _, _}), do: {:failed, failure_kind(reason)}
  defp outcome({:cancel, reason}), do: {:failed, failure_kind(reason)}
  defp outcome(_result), do: {:succeeded, nil}

  defp normalize_identifiers(attrs) do
    Enum.reduce([:provider, :operation, :stage], attrs, fn key, acc ->
      case acc[key] do
        value when is_atom(value) and not is_nil(value) ->
          Map.put(acc, key, Atom.to_string(value))

        _ ->
          acc
      end
    end)
  end

  defp interrupt_previous_attempts(%{job_id: job_id, job_attempt: job_attempt})
       when is_integer(job_id) and is_integer(job_attempt) do
    Repo.update_all(
      from(a in ProcessingAttempt,
        where: a.job_id == ^job_id and a.job_attempt < ^job_attempt and a.status == :running
      ),
      set: [
        status: :interrupted,
        failure_kind: "worker_interrupted",
        finished_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp interrupt_previous_attempts(_attrs), do: :ok
end
