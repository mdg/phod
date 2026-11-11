defmodule Phod.Tool.Patch do
  @moduledoc """
  Applies a diff to one file. The diff is first piped to the `patch` CLI on
  stdin. If `patch` rejects it, the `***` envelope lines at the start and end
  are trimmed and it is tried again. If that also fails, the hunks are applied
  in Elixir by matching their text, which ignores line numbers (see
  `Phod.Tool.Patch.Hunks`).

  Each `patch` attempt runs with `--dry-run` first, so a diff that fails
  partway through leaves the file untouched. The path is validated through
  `Phod.Tool.Input` like the other file tools, so it must stay inside the
  worktree; `allow_new_path` lets a diff against `/dev/null` create a file.
  """

  import Rexult

  alias Phod.Tool
  alias Phod.Tool.Patch.Hunks

  @behaviour Tool.B

  @hunk_header ~r/^@@/

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
    full_path = Path.join(root, path)
    created? = not File.exists?(full_path)
    trimmed = trim_envelope(diff)

    # The attempts run in order until one applies: the diff as given, the
    # trimmed diff (skipped when trimming changed nothing), then the
    # programmatic hunk matcher.
    patch_attempts =
      [{"patch", diff <> "\n"}, {"patch after trimming *** lines", trimmed}]
      |> Enum.uniq_by(fn {_method, text} -> text end)
      |> Enum.map(fn {method, text} -> fn -> patch_cli(full_path, method, text) end end)

    (patch_attempts ++ [fn -> programmatic(full_path, trimmed) end])
    |> first_success()
    |> map_err(fn errors -> "could not apply the diff:\n" <> Enum.join(errors, "\n") end)
    |> ok_and_then(fn result -> {:ok, Map.merge(%{path: path, created?: created?}, result)} end)
  end

  # Runs each attempt in turn and returns the first success. Failures are
  # collected so the final message can report every one.
  defp first_success(attempts) do
    Enum.reduce_while(attempts, {:error, []}, fn attempt, {:error, errors} ->
      case attempt.() do
        {:ok, _} = ok -> {:halt, ok}
        {:error, msg} -> {:cont, {:error, errors ++ [msg]}}
      end
    end)
  end

  # Drops `***` envelope lines and blank lines from both ends of the diff.
  # The result always ends with a newline, as `patch` expects.
  defp trim_envelope(diff) do
    diff
    |> String.split("\n")
    |> Enum.drop_while(&envelope_or_blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&envelope_or_blank?/1)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp envelope_or_blank?(line), do: String.starts_with?(line, "***") or String.trim(line) == ""

  defp patch_cli(full_path, method, text) do
    run_patch(full_path, text, ["--dry-run"])
    |> ok_and_then(fn _ -> run_patch(full_path, text, []) end)
    |> ok_and_then(fn %Rambo{out: out} ->
      {:ok, %{method: method, applied_hunks: count_hunks(text), output: String.trim(out)}}
    end)
  end

  defp run_patch(full_path, text, extra) do
    args = ["--batch", "--forward"] ++ extra ++ ["--", full_path]

    Rambo.run("patch", args, in: text, log: false)
    |> patch_result()
  end

  defp patch_result({:ok, %Rambo{}} = ok), do: ok

  defp patch_result({:error, %Rambo{status: status, out: out, err: err}}) do
    {:error, "patch failed (exit #{status}): #{String.trim(out <> err)}"}
  end

  defp patch_result({:error, reason}), do: {:error, "could not run patch: #{reason}"}

  defp programmatic(full_path, text) do
    text
    |> Hunks.parse()
    |> ok_and_then(fn hunks ->
      full_path
      |> read_content()
      |> ok_and_then(&Hunks.apply_hunks(&1, hunks))
      |> ok_and_then(&write_content(full_path, &1, length(hunks)))
    end)
  end

  # A missing file reads as empty, so a diff can create it.
  defp read_content(full_path) do
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, "could not read the file: #{:file.format_error(reason)}"}
    end
  end

  defp write_content(full_path, content, hunk_count) do
    case File.write(full_path, content) do
      :ok ->
        {:ok,
         %{
           method: "programmatic",
           applied_hunks: hunk_count,
           output: "matched #{hunk_count} hunk(s) by their text; line numbers were ignored"
         }}

      {:error, reason} ->
        {:error, "could not write the file: #{:file.format_error(reason)}"}
    end
  end

  # Every hunk must apply for `patch` to succeed, so the count of `@@` headers
  # in the diff is the number of hunks applied.
  defp count_hunks(diff) do
    diff |> String.split("\n") |> Enum.count(&Regex.match?(@hunk_header, &1))
  end
end
