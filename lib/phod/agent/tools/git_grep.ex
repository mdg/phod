defmodule Phod.Agent.Tool.GitGrep do
  @moduledoc false

  @behaviour Phod.Agent.Tool

  @max_results 50

  @impl Phod.Agent.Tool
  def name, do: "git_grep"

  @impl Phod.Agent.Tool
  def description,
    do: """
    Search file contents across the worktree with a regular expression \
    (POSIX extended syntax; runs `grep` internally, hence the name). Returns \
    matching paths, line numbers, and line texts. Use this to find where code \
    lives before editing it. Paths in results are relative to the worktree root.\
    """

  @impl Phod.Agent.Tool
  def run(root, input) do
    case Map.get(input, "pattern") do
      pattern when is_binary(pattern) and pattern != "" ->
        search(root, pattern, Map.get(input, "path", "."))

      other ->
        {:error, "pattern must be a non-empty string, got: #{inspect(other)}"}
    end
  end

  defp search(root, pattern, path) do
    case Phod.Agent.Tool.resolve(root, path) do
      {:ok, absolute} ->
        subdir = Phod.Agent.Tool.relative_path(root, absolute)

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
          subdir
        ]

        case System.cmd("grep", args, cd: root, stderr_to_stdout: true) do
          {output, 0} ->
            matches =
              output
              |> String.split("\n", trim: true)
              |> Enum.reject(&String.starts_with?(&1, "grep: "))
              |> Enum.take(@max_results)
              |> Enum.map(&parse_line/1)

            {:ok, %{matches: matches, truncated?: length(matches) == @max_results}}

          {stderr, 1} when stderr == "" ->
            {:ok, %{matches: [], truncated?: false}}

          {stderr, 2} ->
            case stderr |> String.trim() |> String.replace(~r/^(\S*grep: )+/, "") do
              "" -> {:error, "invalid expression or unreadable path (grep status 2)"}
              reason -> {:error, "invalid regular expression: " <> reason}
            end

          {_stdout, code} ->
            {:error, "grep exited with status #{code}"}
        end

      {:error, reason} ->
        {:error, reason}
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
