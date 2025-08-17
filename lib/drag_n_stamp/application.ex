defmodule DragNStamp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load environment variables from .env file in development only
    if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
      load_env_file()
    end

    children = [
      DragNStampWeb.Telemetry,
      DragNStamp.Repo,
      {DNSCluster, query: Application.get_env(:drag_n_stamp, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DragNStamp.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: DragNStamp.Finch},
      # Start a worker by calling: DragNStamp.Worker.start_link(arg)
      # {DragNStamp.Worker, arg},
      # Start to serve requests, typically the last entry
      DragNStampWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DragNStamp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DragNStampWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp load_env_file do
    env_file = ".env"

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)

            if key != "" and value != "" do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end)
    end
  end
end
