defmodule Mix.Tasks.Stampbot.PluginStats do
  @shortdoc "Reports plugin requests, estimated users, return use, results, and costs"
  @moduledoc "Usage: mix stampbot.plugin_stats [--hours 168] [--json]. Starts only the Repo, never workers or provider calls."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [hours: :integer, json: :boolean])
    hours = Keyword.get(opts, :hours, 168)

    unless rest == [] and invalid == [] and hours in 1..2_160,
      do: Mix.raise("Usage: mix stampbot.plugin_stats [--hours 1..2160] [--json]")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    if is_nil(Process.whereis(DragNStamp.Repo)),
      do: {:ok, _} = DragNStamp.Repo.start_link(log: false)

    level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    report =
      try do
        DragNStamp.Plugin.Stats.snapshot(hours: hours)
      after
        if level,
          do: Logger.put_process_level(self(), level),
          else: Logger.delete_process_level(self())
      end

    if opts[:json] do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      Mix.shell().info("StampBot plugin, last #{hours} hours")

      Mix.shell().info(
        "Generation requests: #{report.generate_calls}; accepted: #{report.accepted_generate_calls}; new jobs: #{report.new_jobs}; cached results: #{report.cached_generate_calls}"
      )

      Mix.shell().info(
        "Estimated requesting subjects: #{report.requesting_subjects}; returning: #{report.returning_subjects}; accepted calls without a subject: #{report.accepted_calls_without_subject}"
      )

      Mix.shell().info(
        "Ready deliveries: #{report.ready_deliveries}; status checks: #{report.status_checks}"
      )

      Mix.shell().info(
        "Current generated-result cost: $#{report.current_generated_result_cost_usd || "unknown"}; incomplete estimates: #{report.results_with_incomplete_cost}"
      )

      for result <- report.current_generated_results,
          do: Mix.shell().info("Generated results/#{result.status}: #{result.count}")

      for outcome <- report.outcomes,
          do:
            Mix.shell().info(
              "#{outcome.operation}/#{outcome.outcome}/#{outcome.reason || "none"}: #{outcome.count}"
            )

      Mix.shell().info(report.measurement_note)
      Mix.shell().info(report.cost_note)
    end
  end
end
