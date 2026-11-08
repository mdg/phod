defmodule Phod.Tool.Rm do
  @moduledoc """
  Removes files from the worktree. Every path is checked before anything is
  removed, so one bad path leaves the worktree untouched. Directories are not
  removed. Paths under `.git` are refused by the path type. A symlink is
  removed as a link; its target is left alone.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "rm"

  @impl Tool.B
  def description,
    do: """
    Remove one or more files in the worktree. Paths are relative to the \
    worktree root. Directories cannot be removed, and nothing under .git can \
    be. Every path is checked before any file is removed.\
    """

  @impl Tool.B
  def params do
    [
      Tool.Input.link_paths(:paths, "Files to remove, relative to the worktree root.",
        required: true
      )
    ]
  end

  @impl Tool.B
  def run(%{paths: paths}, %{session_root: root}) do
    case Enum.find_value(paths, &refusal(root, &1)) do
      nil -> remove_all(root, paths)
      reason -> {:error, reason}
    end
  end

  # The first reason a path can't be removed, or nil if it can.
  defp refusal(root, path) do
    case File.lstat(Path.join(root, path)) do
      {:ok, %File.Stat{type: :directory}} -> "#{path} is a directory, not a file"
      {:ok, _stat} -> nil
      {:error, reason} -> "could not remove #{path}: #{Tool.Lib.format_error(reason)}"
    end
  end

  defp remove_all(root, paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, removed} ->
      case File.rm(Path.join(root, path)) do
        :ok ->
          {:cont, {:ok, [path | removed]}}

        {:error, reason} ->
          {:halt, {:error, "could not remove #{path}: #{Tool.Lib.format_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, %{removed: Enum.reverse(removed)}}
      {:error, _reason} = error -> error
    end
  end
end
