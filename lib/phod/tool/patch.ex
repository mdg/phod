defmodule Phod.Tool.Patch do
  @moduledoc """
  Applies a unified diff to one file by piping the diff to the `patch` CLI
  on stdin (via `Rambo.run/3`'s `:in` option). The path is validated through
  `Phod.Tool.Input` like the other file tools, so it must stay inside the
  worktree; `allow_new_path` lets a diff against `/dev/null` create a file.
  """

  import Rexult

  alias Phod.Tool

  @behaviour Tool.B

  @envelope_error """
  not a unified diff: remove the "*** Begin Patch", "*** Update File:", \
  "*** Add File:", "*** Delete File:", and "*** End Patch" lines. Start the \
  diff with "--- path" and "+++ path", then hunks headed like "@@ -12,4 +12,5 @@" \
  whose counts match the lines in the hunk.\
  """

  @hunk_error """
  a hunk header must give line numbers and counts, like "@@ -12,4 +12,5 @@" \
  (old start, old count, new start, new count). A bare "@@" is not valid.\
  """

  @hunk_header ~r/^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/

  @impl Tool.B
  def name, do: "patch"

  @impl Tool.B
  def description,
    do: """
    Apply a unified diff to one file in the worktree using the `patch` \
    utility. Provide the diff in standard unified format, and nothing else: \
    no "*** Begin Patch" / "*** End Patch" or "*** Update File:" lines. Every \
    hunk header gives line numbers and counts. To create a new file, diff \
    against /dev/null. After applying, verify the result with read_files. \
    Delete files with the rm tool instead of using patch. \
    Example, changing the second line of notes.txt:\n\
    --- a/notes.txt\n\
    +++ b/notes.txt\n\
    @@ -1,3 +1,3 @@\n\
     one\n\
    -two\n\
    +TWO\n\
     three\n\
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
    check_format(diff)
    |> ok_and_then(fn diff -> apply_diff(root, path, diff) end)
  end

  # `patch` reads anything it doesn't understand as part of a hunk, so the
  # format is checked first, and the error says what to change.
  defp check_format(diff) do
    lines = String.split(diff, "\n")

    cond do
      Enum.any?(lines, &String.starts_with?(&1, "*** ")) ->
        {:error, String.trim(@envelope_error)}

      Enum.any?(lines, &(String.starts_with?(&1, "@@") and not Regex.match?(@hunk_header, &1))) ->
        {:error, String.trim(@hunk_error)}

      true ->
        {:ok, diff}
    end
  end

  defp apply_diff(root, path, diff) do
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
           output: String.trim(out),
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
