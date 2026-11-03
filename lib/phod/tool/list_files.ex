defmodule Phod.Tool.ListFiles do
  @moduledoc false

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: :list_files

  @impl Tool.B
  def description,
    do: """
    List the contents of a directory in the worktree. Returns names with a `/` \
    suffix for directories. Use this to explore the project structure. \
    Paths are relative to the worktree root; defaults to the root. \
    Does not recurse — call it again on subdirectories.\
    """

  @impl Tool.B
  def run(root, input) do
    path = Map.get(input, "path", ".")

    case Tool.Lib.resolve(root, path) do
      {:ok, absolute} ->
        case File.ls(absolute) do
          {:ok, names} ->
            entries =
              for name <- Enum.sort(names) do
                type =
                  if File.dir?(Path.join(absolute, name)), do: "dir", else: "file"

                %{name: name, type: type}
              end

            {:ok, %{path: Tool.Lib.relative_path(root, absolute), entries: entries}}

          {:error, reason} ->
            {:error, "could not list #{inspect(path)}: #{Tool.Lib.format_error(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
