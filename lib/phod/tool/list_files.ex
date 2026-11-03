defmodule Phod.Tool.ListFiles do
  @moduledoc false

  import Rexult

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
  def tool_fields() do
    [:path]
  end

  @impl Tool.B
  def run(%Tool.Input{} = input) do
    File.ls(input.full_path)
    |> map_ok(fn names ->
      entries =
        Enum.sort(names)
        |> Enum.map(fn name ->
          full_name = Path.join(input.full_path, name)
          type = if File.dir?(full_name), do: "dir", else: "file"
          %{name: name, type: type}
        end)

      %{
        path: input.path,
        entries: entries,
      }
    end)
    |> map_err(fn reason ->
      "could not list #{inspect(input.path)}: #{Tool.Lib.format_error(reason)}"
    end)
  end
end
