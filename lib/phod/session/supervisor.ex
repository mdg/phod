defmodule Phod.Session.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Phod.Session` processes, started on demand and
  shut down when idle.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(String.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(id, worktree_root, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Phod.Session, {id, worktree_root, opts}})
  end
end
