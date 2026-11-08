defmodule Phod.Tool.Grep do
  @moduledoc false

  alias Phod.Tool

  import Rexult

  require Logger

  @behaviour Tool.B

  @max_results 50

  @impl Tool.B
  def name, do: "grep"

  @impl Tool.B
  def description,
    do: """
    Search file contents across the worktree with one or more regular \
    expressions (Rust regex syntax; runs `ripgrep` internally). Patterns are \
    regular expressions, so escape special characters such as ( ) [ ] { } . * + \
    ? | ^ $ and backslash with a backslash to match them literally. Provide a \
    list of one or more patterns - matches are the union of all given \
    patterns. Returns matching paths, line numbers, and line texts. Use this \
    to find where code lives before editing it. Paths in results are \
    relative to the worktree root.\
    """

  @impl Tool.B
  def params() do
    [
      Tool.Input.path(required: false) |> Tool.Input.optional("."),
      Tool.Input.patterns(),
    ]
  end

  @impl Tool.B
  def run(%{path: path, patterns: patterns}, %{session_root: root}) do
    args = ["--json"] ++ Enum.flat_map(patterns, &["-e", &1]) ++ ["--", path]

    case Rambo.run("rg", args, cd: root, log: false) do
      {:ok, %Rambo{out: output}} ->
        {:ok, output}

      # no matches: treat as an ok result with no output
      {:error, %Rambo{status: 1}} ->
        {:ok, ""}

      {:error, %Rambo{status: status, err: err}} ->
        Logger.error("grep error", status: status)
        {:error, err}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
    |> map_ok(&(&1 |> parse_output() |> Map.put(:patterns, patterns)))
    |> map_err(&normalize_rg_error/1)
    |> on_err(fn reason -> Logger.warning("grep failed: " <> reason) end)
  end

  # ripgrep's --json output is newline-delimited JSON events; only "match"
  # events carry a result, the rest ("begin"/"end"/"summary") are ignored.
  # rg runs with cwd set to the worktree root and `input.path` as its search
  # target, so its reported paths are already root-relative — except when
  # the target is "." (searching the whole worktree), where rg prefixes
  # matches with "./" that we strip for a consistent root-relative path.
  defp parse_output("") do
    %{matches: [], truncated?: false}
  end

  defp parse_output(output) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_match/1)
      |> Enum.take(@max_results)

    %{matches: matches, truncated?: length(matches) == @max_results}
  end

  defp decode_match(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        [
          %{
            path: String.trim_leading(data["path"]["text"], "./"),
            line_number: data["line_number"],
            line: String.trim_trailing(data["lines"]["text"], "\n")
          }
        ]

      _ ->
        []
    end
  end

  defp normalize_rg_error(output) do
    case String.trim(output) do
      "" -> "invalid expression or unreadable path (no error message)"
      reason -> reason
    end
  end
end
