defmodule PhodWeb.SessionLive.FileTree do
  @moduledoc """
  Pure expand-on-click state for the file explorer pane, backed by the same
  `Phod.Tool.run("list_files", ...)` call the agent itself uses — no
  separate recursive listing tool, just one non-recursive call per expanded
  directory.

  Kept free of any LiveView/Phoenix dependency so it's unit-testable on its
  own.
  """

  @type entries :: {:ok, [%{name: String.t(), type: String.t()}]} | {:error, String.t()}
  @type t :: %__MODULE__{expanded: MapSet.t(String.t()), entries: %{String.t() => entries()}}

  defstruct expanded: MapSet.new(), entries: %{}

  @doc "A fresh tree with the worktree root expanded."
  @spec new(String.t()) :: t()
  def new(root) do
    toggle(%__MODULE__{}, root, ".")
  end

  @doc """
  Expands `path` (fetching its listing) if collapsed, or collapses it if
  already expanded.
  """
  @spec toggle(t(), String.t(), String.t()) :: t()
  def toggle(%__MODULE__{} = tree, root, path) do
    if MapSet.member?(tree.expanded, path) do
      %{tree | expanded: MapSet.delete(tree.expanded, path)}
    else
      %{
        tree
        | expanded: MapSet.put(tree.expanded, path),
          entries: Map.put(tree.entries, path, fetch(root, path))
      }
    end
  end

  @doc "Re-fetches the listing for every currently expanded directory."
  @spec refresh_expanded(t(), String.t()) :: t()
  def refresh_expanded(%__MODULE__{} = tree, root) do
    entries =
      Enum.reduce(tree.expanded, tree.entries, fn path, acc ->
        Map.put(acc, path, fetch(root, path))
      end)

    %{tree | entries: entries}
  end

  defp fetch(root, path) do
    case Phod.Tool.run("list_files", root, %{"path" => path}) do
      {:ok, %{entries: entries}} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end
end
