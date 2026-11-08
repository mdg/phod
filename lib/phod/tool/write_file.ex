defmodule Phod.Tool.WriteFile do
  @moduledoc """
  Writes a whole file in the worktree: creates it (and any missing parent
  directories) or replaces its contents. The path is validated like `patch`'s,
  so it stays inside the worktree, follows symlinks to in-worktree targets, and
  never reaches `.git`.
  """

  import Rexult

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "write_file"

  @impl Tool.B
  def description,
    do: """
    Write a whole file in the worktree. Creates the file, and any missing parent \
    directories, if it doesn't exist; replaces its contents if it does. Paths \
    are relative to the worktree root. Use patch to change part of an existing \
    file; use write_file for new files or full rewrites. Verify with read_files \
    afterwards.\
    """

  @impl Tool.B
  def params do
    [
      Tool.Input.path(:path, "File to write, relative to the worktree root. It may not exist yet.",
        required: true,
        allow_new_path: true
      ),
      Tool.Input.string(:content, "The complete contents of the file.", required: true)
    ]
  end

  @impl Tool.B
  def run(%{path: path, content: content}, %{session_root: root}) do
    full_path = Path.join(root, path)
    created? = not File.exists?(full_path)

    File.mkdir_p(Path.dirname(full_path))
    |> rexult()
    |> ok_and_then(fn _ -> File.write(full_path, content) |> rexult() end)
    |> map_ok(fn _ -> %{path: path, created?: created?, bytes: byte_size(content)} end)
    |> map_err(&write_error(path, &1))
  end

  defp write_error(path, :eisdir), do: "#{inspect(path)} is a directory, not a file"
  defp write_error(path, reason), do: "could not write #{inspect(path)}: " <> Tool.Lib.format_error(reason)
end
