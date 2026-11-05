defmodule Phod.Tool.ListFiles do
  @moduledoc false

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "list_files"

  @impl Tool.B
  def description,
    do: """
    List the contents of a directory in the worktree by running `ls -lF`. \
    Returns the raw `ls -lF` output (permissions, owner, size, modified \
    time, and name), with a trailing `/` on directory names and `*` on \
    executable files. If `path` names a file instead of a directory, shows \
    that file's own listing line. Use this to explore the project structure. \
    Paths are relative to the worktree root; defaults to the root. \
    Does not recurse — call it again on subdirectories.\
    """

  @impl Tool.B
  def tool_fields() do
    [:path]
  end

  @impl Tool.B
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory path relative to the worktree root. Defaults to the root (\".\") when omitted."
        }
      },
      "required" => []
    }
  end

  @impl Tool.B
  def run(%Tool.Input{} = input) do
    case System.cmd("ls", ["-lF", input.full_path], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, %{path: input.path, output: output}}

      {output, status} ->
        {:error, "could not list #{inspect(input.path)}: #{status} #{String.trim(output)}"}
    end
  end
end
