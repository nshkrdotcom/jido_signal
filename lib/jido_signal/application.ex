defmodule Jido.Signal.Application do
  @moduledoc """
  The main application module for Jido Signal.

  This module handles the initialization and supervision of the signal processing
  infrastructure, including the Registry and Task Supervisor.
  """
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
