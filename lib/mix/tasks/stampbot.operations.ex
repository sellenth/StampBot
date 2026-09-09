defmodule Mix.Tasks.Stampbot.Operations do
  @shortdoc "Reports queue age, processing outcomes, unknown costs, and uncertain publication"
  @moduledoc """
  Usage: mix stampbot.operations [--hours 24] [--json]

  The report reads durable database state and performs no provider requests.
  Dollar allowance reservations are planning estimates, not billing guarantees.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [hours: :integer, json: :boolean])
    hours = Keyword.get(opts, :hours, 24)

    unless rest == [] and invalid == [] and hours in 1..720,
      do: Mix.raise("Usage: mix stampbot.operations [--hours 1..720] [--json]")

    # A Repo-only CLI cannot accidentally start queue consumers or publication.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    if is_nil(Process.whereis(DragNStamp.Repo)),
      do: {:ok, _} = DragNStamp.Repo.start_link(log: false)

    report =
      if opts[:json] do
        # Also keep JSON clean when the task is invoked with an already running
        # Repo. This changes only this caller's logger level and restores it.
        level = Logger.get_process_level(self())
        Logger.put_process_level(self(), :none)

        try do
          DragNStamp.Operations.snapshot(hours: hours)
        after
          if level,
            do: Logger.put_process_level(self(), level),
            else: Logger.delete_process_level(self())
        end
      else
        DragNStamp.Operations.snapshot(hours: hours)
      end

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      Mix.shell().info("StampBot operations, last #{hours} hours")

      for queue <- report.queues do
        Mix.shell().info(
          "#{queue.queue}/#{queue.state}: #{queue.count}, oldest age #{queue.oldest_age_seconds}s"
        )
      end

      for stage <- report.stage_outcomes do
        duration =
          if stage.mean_duration_ms, do: Float.round(stage.mean_duration_ms, 1), else: "unknown"

        Mix.shell().info(
          "#{stage.stage}/#{stage.status}: #{stage.count}, mean duration #{duration}ms"
        )
      end

      for outcome <- report.request_outcomes do
        Mix.shell().info(
          "#{outcome.operation} requests/#{outcome.status}/#{outcome.failure_kind || "none"}: #{outcome.count}"
        )
      end

      Mix.shell().info(
        "Provider requests: #{report.request_count}; known estimated cost: $#{report.known_estimated_cost_usd || "unknown"}; requests with unknown cost: #{report.unknown_cost_request_count}"
      )

      Mix.shell().info(
        "Open attempts: #{report.running_attempt_count}; orphaned: #{report.orphaned_attempt_count}; interrupted: #{report.interrupted_attempt_count}; uncertain publications: #{report.uncertain_publishing_count}"
      )

      for item <- report.uncertain_publishing do
        Mix.shell().info(
          "Uncertain publication: submission #{item.timestamp_id}, last attempted #{item.last_attempt_at || "unknown"}; reconcile on YouTube before retrying"
        )
      end

      allowance = report.work_allowances

      Mix.shell().info(
        "Today's reserved allowance: $#{allowance.reserved_allowance_usd} / $#{allowance.daily_allowance_limit_usd}; requests #{allowance.requests_claimed}/#{allowance.daily_request_limit}; submissions #{allowance.submissions_reserved}/#{allowance.daily_submission_limit}"
      )

      Mix.shell().info(allowance.accounting_note)
    end
  end
end
