defmodule Phod.Tool.ReadFiles do
  @moduledoc """
  Reads one or more files in the worktree, numbering each line. Every path is
  validated before any file is read. A file that can't be read is reported in
  its own entry, and the other files are still returned.
  """

  import Rexult

  alias Phod.Tool

  @behaviour Tool.B

  @max_lines 2_000

  @impl Tool.B
  def name, do: "read_files"

  @impl Tool.B
  def description,
    do: """
    Read the contents of one or more files in the worktree, with line numbers. \
    Use list_files first to discover paths. Paths are relative to the worktree \
    root. A file that can't be read (missing, or a directory) is reported in its \
    own entry, and the other files are still returned.\
    """

  @impl Tool.B
  def params() do
    [
      Tool.Input.paths(:paths, "Files to read, relative to the worktree root.",
        required: true
      ),
    ]
  end

  @impl Tool.B
  def run(%{paths: paths}, %{session_root: root}) do
    {:ok, %{files: Enum.map(paths, &read_one(root, &1))}}
  end

  defp read_one(root, path) do
    Path.join(root, path)
    |> File.read()
    |> map_ok(&%{path: path, content: format_content(&1)})
    |> map_err(&%{path: path, error: read_error(path, &1)})
    |> unwrap_entry()
  end

  defp unwrap_entry({:ok, entry}), do: entry
  defp unwrap_entry({:error, entry}), do: entry

  defp read_error(path, :enoent), do: "#{inspect(path)} does not exist"
  defp read_error(path, :eisdir), do: "#{inspect(path)} is a directory, use list_files"

  defp read_error(path, reason),
    do: "could not read #{inspect(path)}: " <> Tool.Lib.format_error(reason)

  defp format_content(content) do
    lines =
      content
      |> String.trim_trailing("\n")
      |> String.split("\n")

    numbered =
      lines
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {line, i} -> "#{i}: #{line}" end)

    if length(lines) > @max_lines do
      numbered <>
        "\n... (truncated: file has #{length(lines)} lines; showing first #{@max_lines})"
    else
      numbered
    end
  end
end
