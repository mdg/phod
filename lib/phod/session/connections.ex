defmodule Phod.Session.Connections do
  @moduledoc """
  The links between sessions, kept in memory. A link `{from, to}` means `from`
  may send messages to `to`. A mutual connection is two links.

  Only `Phod.Session` uses this. It sits behind this module so the storage can
  move to a database later without touching callers.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
  end

  @spec link?(String.t(), String.t()) :: boolean()
  def link?(from, to), do: Agent.get(__MODULE__, &MapSet.member?(&1, {from, to}))

  @spec add_link(String.t(), String.t()) :: :ok
  def add_link(from, to), do: Agent.update(__MODULE__, &MapSet.put(&1, {from, to}))

  @spec remove_link(String.t(), String.t()) :: :ok
  def remove_link(from, to), do: Agent.update(__MODULE__, &MapSet.delete(&1, {from, to}))

  @doc "The sessions `id` may send messages to, sorted."
  @spec peers(String.t()) :: [String.t()]
  def peers(id) do
    Agent.get(__MODULE__, fn links ->
      for {from, to} <- links, from == id, do: to
    end)
    |> Enum.sort()
  end
end
