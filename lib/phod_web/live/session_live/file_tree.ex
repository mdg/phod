defmodule PhodWeb.SessionLive.FileTree do
  @moduledoc """
  Pure expand-on-click state for the file explorer pane, backed by the same
  `Phod.Tool.run("list_files", ...)` call the agent itself uses — no
  separate recursive listing tool, just one non-recursive call per expanded
  directory.

  The tool returns raw `ls -lF` output (so the LLM sees exactly what a
  human running `ls` would); this module parses that text back into
  `name`/`type` pairs for rendering. The parse takes the last
  whitespace-separated field as the name, so it mishandles filenames that
  themselves contain spaces — an accepted limitation of reusing `ls -lF`'s
  output as the data format.

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
      {:ok, %{output: output}} -> {:ok, parse_ls(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_ls(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "total "))
    |> Enum.map(&parse_line/1)
  end

  defp parse_line(line) do
    name_field = line |> String.split(~r/\s+/, trim: true) |> List.last()

    if String.ends_with?(name_field, "/") do
      %{name: String.slice(name_field, 0..-2//1), type: "dir"}
    else
      %{name: name_field, type: "file"}
    end
  end
end
