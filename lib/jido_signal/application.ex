defmodule Jido.Signal.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Jido.Signal.Registry},

      # Exec Async Actions Task Supervisor
      {Task.Supervisor, name: Jido.Signal.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Jido.Signal.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
