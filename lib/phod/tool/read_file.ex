defmodule Phod.Tool.ReadFile do
  @moduledoc false

  alias Phod.Tool

  @behaviour Tool.B

  @max_lines 2_000

  @impl Tool.B
  def name, do: :read_file

  @impl Tool.B
  def description,
    do: """
    Read the contents of one file in the worktree. Use list_files first to \
    discover paths. Paths are relative to the worktree root. Reading a \
    non-existent path or a directory returns an error.\
    """

  @impl Tool.B
  def run(root, input) do
    path = Map.get(input, "path")

    case Tool.Lib.resolve(root, path) do
      {:ok, absolute} ->
        case File.read(absolute) do
          {:ok, content} ->
            {:ok,
             %{
               path: Tool.Lib.relative_path(root, absolute),
               content: format_content(content)
             }}

          {:error, :eisdir} ->
            {:error, "#{inspect(path)} is a directory; use list_files on it"}

          {:error, reason} ->
            {:error, "could not read #{inspect(path)}: #{Tool.Lib.format_error(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
