defmodule Phod.Session.Connections do
  @moduledoc """
  The links between sessions. A link `{from, to}` means `from` may send messages
  to `to`; a mutual connection is two links.

  The links are saved to `<worktree_base>/peers.json` whenever they change, and
  loaded when the application starts, before any session is running. A loaded
  link needs no running session: it simply can't deliver a message until its
  session starts. A missing file means no links. A file that can't be used is
  logged, and the store starts with no links and refuses changes, so the file
  isn't overwritten.

  Only `Phod.Session` uses this. It sits behind this module so the storage can
  move to a database later without touching callers.
  """

  use Agent

  require Logger

  def start_link(_opts) do
    Agent.start_link(fn -> load() end, name: __MODULE__)
  end

  @spec link?(String.t(), String.t()) :: boolean()
  def link?(from, to), do: Agent.get(__MODULE__, &MapSet.member?(&1.links, {from, to}))

  @doc "The sessions `id` may send messages to, sorted."
  @spec peers(String.t()) :: [String.t()]
  def peers(id) do
    Agent.get(__MODULE__, fn %{links: links} ->
      for {from, to} <- links, from == id, do: to
    end)
    |> Enum.sort()
  end

  @doc "Adds links, and saves them. Returns an error, and changes nothing, if the save fails."
  @spec add_links([{String.t(), String.t()}]) :: :ok | {:error, term()}
  def add_links(pairs), do: change(&MapSet.union(&1, MapSet.new(pairs)))

  @doc "Removes links, and saves them. Returns an error, and changes nothing, if the save fails."
  @spec remove_links([{String.t(), String.t()}]) :: :ok | {:error, term()}
  def remove_links(pairs), do: change(&MapSet.difference(&1, MapSet.new(pairs)))

  defp change(update) do
    Agent.get_and_update(__MODULE__, fn state ->
      if state.error do
        {{:error, {:invalid_peers_file, state.error}}, state}
      else
        links = update.(state.links)

        case write(links) do
          :ok -> {:ok, %{state | links: links}}
          {:error, reason} -> {{:error, {:save_failed, reason}}, state}
        end
      end
    end)
  end

  # Loading and saving ---------------------------------------------------------

  defp path do
    Path.join(Application.fetch_env!(:phod, :worktree_base), "peers.json")
  end

  defp load do
    case read(path()) do
      {:ok, links} ->
        %{links: links, error: nil}

      {:error, reason} ->
        Logger.error("peers file #{path()} is invalid, starting with no peers: #{inspect(reason)}")
        %{links: MapSet.new(), error: reason}
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> decode(text)
      {:error, :enoent} -> {:ok, MapSet.new()}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{"links" => links}} when is_list(links) ->
        if Enum.all?(links, &valid_pair?/1),
          do: {:ok, MapSet.new(links, fn [from, to] -> {from, to} end)},
          else: {:error, :invalid_shape}

      {:ok, _other} ->
        {:error, :invalid_shape}

      {:error, error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp valid_pair?([from, to]), do: is_binary(from) and is_binary(to)
  defp valid_pair?(_other), do: false

  defp write(links) do
    json =
      %{"links" => links |> Enum.sort() |> Enum.map(fn {from, to} -> [from, to] end)}
      |> Jason.encode!(pretty: true)

    temp = path() <> ".tmp"

    case File.write(temp, json) do
      :ok -> File.rename(temp, path())
      {:error, _reason} = error -> error
    end
  end
end
