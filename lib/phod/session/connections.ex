defmodule Phod.Session.Connections do
  @moduledoc """
  The links between sessions, and each session's description, kept in memory.

  A link `{from, to}` means `from` may send messages to `to`. A mutual
  connection is two links. A session's description comes from its worktree's
  `DESCRIPTION.md` when it starts, and tells its peers what it's for.

  Only `Phod.Session` uses this. It sits behind this module so the storage can
  move to a database later without touching callers.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{links: MapSet.new(), descriptions: %{}} end, name: __MODULE__)
  end

  @spec link?(String.t(), String.t()) :: boolean()
  def link?(from, to) do
    Agent.get(__MODULE__, &MapSet.member?(&1.links, {from, to}))
  end

  @spec add_link(String.t(), String.t()) :: :ok
  def add_link(from, to) do
    Agent.update(__MODULE__, &%{&1 | links: MapSet.put(&1.links, {from, to})})
  end

  @spec remove_link(String.t(), String.t()) :: :ok
  def remove_link(from, to) do
    Agent.update(__MODULE__, &%{&1 | links: MapSet.delete(&1.links, {from, to})})
  end

  @doc "The sessions `id` may send messages to, sorted."
  @spec peers(String.t()) :: [String.t()]
  def peers(id) do
    Agent.get(__MODULE__, fn %{links: links} ->
      for {from, to} <- links, from == id, do: to
    end)
    |> Enum.sort()
  end

  @doc "Records a session's description, or clears it with `nil`."
  @spec set_description(String.t(), String.t() | nil) :: :ok
  def set_description(id, description) do
    Agent.update(__MODULE__, fn state ->
      %{state | descriptions: Map.put(state.descriptions, id, description)}
    end)
  end

  @doc "A session's description, or `nil` if it has none."
  @spec description(String.t()) :: String.t() | nil
  def description(id) do
    Agent.get(__MODULE__, &Map.get(&1.descriptions, id))
  end
end
