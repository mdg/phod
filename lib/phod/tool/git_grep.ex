defmodule Phod.Tool.GitGrep do
  @moduledoc false

  alias Phod.Tool

  import Rexult

  require Logger

  @behaviour Tool.B

  @max_results 50

  @impl Tool.B
  def name, do: :git_grep

  @impl Tool.B
  def description,
    do: """
    Search file contents across the worktree with a regular expression \
    (POSIX extended syntax; runs `grep` internally, hence the name). Returns \
    matching paths, line numbers, and line texts. Use this to find where code \
    lives before editing it. Paths in results are relative to the worktree root.\
    """

  @impl Tool.B
  def tool_fields() do
    [:path, :pattern]
  end

  @impl Tool.B
  def run(%Tool.Input{pattern: pattern} = input) do
    args = [
      "--no-messages",
      "--binary-files=without-match",
      "--exclude-dir=.git",
      "--exclude=.git",
      "--directories=recurse",
      "--with-filename",
      "--line-number",
      "--extended-regexp",
      "--",
      pattern,
      input.path
    ]

    {output, exit_code} = System.cmd("grep", args, cd: input.root, stderr_to_stdout: true)

    result =
      case exit_code do
        0 -> {:ok, output}
        # no matches: treat as an ok result with no output
        1 -> {:ok, ""}
        _ -> {:error, output}
      end

    result
    |> map_ok(&parse_output/1)
    |> map_err(&normalize_grep_error/1)
    |> on_err(fn reason -> Logger.warning("git_grep failed: " <> reason) end)
  end

  # {"path:line:text", ...} -> %{matches: ..., truncated?}
  defp parse_output("") do
    %{matches: [], truncated?: false}
  end

  defp parse_output(output) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "grep: "))
      |> Enum.take(@max_results)
      |> Enum.map(&parse_line/1)

    %{matches: matches, truncated?: length(matches) == @max_results}
  end

  # grep's error output ("path/to/grep: message") -> normalized reason message
  defp normalize_grep_error(output) do
    case output |> String.trim() |> String.replace(~r/^(\S*grep: )+/, "") do
      "" -> "invalid expression or unreadable path (grep error with no message)"
      reason -> "invalid regular expression: " <> reason
    end
  end

  # Output lines are "path:line:text". Paths should not contain colons here in
  # practice, but split defensively on the first two colons only.
  defp parse_line(line) do
    case String.split(line, ":", parts: 3) do
      [path, line_no, text] ->
        %{
          path: String.trim_leading(path, "./"),
          line_number: String.to_integer(line_no),
          line: text
        }

      [line_text] ->
        %{path: nil, line_number: nil, line: line_text}
    end
  end
end
