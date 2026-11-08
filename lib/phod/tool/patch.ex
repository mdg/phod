defmodule Phod.Tool.Patch do
  @moduledoc """
  Applies a unified diff to one file by piping the diff to the `patch` CLI
  on stdin (via `Rambo.run/3`'s `:in` option). The path is validated through
  `Phod.Tool.Input` like the other file tools, so it must stay inside the
  worktree; `allow_new_path` lets a diff against `/dev/null` create a file.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "patch"

  @impl Tool.B
  def description,
    do: """
    Apply a unified diff to one file in the worktree using the `patch` \
    utility. Provide the diff in standard unified format. To create a new \
    file, diff against /dev/null. After applying, verify the result with \
    read_files. \
    The diff contents will be passed directly to the patch command. \
    Include **only** valid inputs to patch. \
    Delete files with the rm_file tool instead of using patch. \
    """

  @impl Tool.B
  def params do
    [
      Tool.Input.path(:path, "File to patch, relative to the worktree root.",
        required: true,
        allow_new_path: true
      ),
      Tool.Input.diff(),
    ]
  end

  @impl Tool.B
  def run(%{path: path, diff: diff}, %{session_root: root}) do
    full_path = Path.join(root, path)
    created? = not File.exists?(full_path)

    case Rambo.run("patch", ["--batch", "--forward", "--", full_path],
           in: diff <> "\n",
           log: false
         ) do
      {:ok, %Rambo{out: out}} ->
        {:ok,
         %{
           path: path,
           created?: created?,
           applied_hunks: count_hunks(diff),
           output: String.trim(out)
         }}

      {:error, %Rambo{status: status, out: out, err: err}} ->
        {:error, "patch failed (exit #{status}): #{String.trim(out <> err)}"}

      {:error, reason} ->
        {:error, "could not run patch: #{reason}"}
    end
  end

  # Every hunk must apply for `patch` to succeed, so the count of `@@` headers
  # in the diff is the number of hunks applied.
  defp count_hunks(diff) do
    diff |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "@@"))
  end
end
