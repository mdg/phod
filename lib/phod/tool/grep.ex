defmodule Phod.Tool.Grep do
  @moduledoc false

  alias Phod.Tool

  import Rexult

  require Logger

  @behaviour Tool.B

  @max_results 50

  @impl Tool.B
  def name, do: :grep

  @impl Tool.B
  def description,
    do: """
    Search file contents across the worktree with one or more regular \
    expressions (Rust regex syntax; runs `ripgrep` internally). Provide a \
    list of one or more patterns - matches are the union of all given \
    patterns. Returns matching paths, line numbers, and line texts. Use this \
    to find where code lives before editing it. Paths in results are \
    relative to the worktree root.\
    """

  @impl Tool.B
  def tool_fields() do
    [:path, :patterns]
  end

  @impl Tool.B
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "patterns" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "One or more regular expressions (Rust regex syntax, as used by ripgrep). " <>
              "Matches are the union of all given patterns."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Subdirectory to search, relative to the worktree root. Defaults to the whole worktree."
        }
      },
      "required" => ["patterns"]
    }
  end

  @impl Tool.B
  def run(%Tool.Input{patterns: patterns} = input) do
    args = ["--json"] ++ Enum.flat_map(patterns, &["-e", &1]) ++ ["--", "."]

    {output, exit_code} =
      System.cmd("rg", args, cd: input.full_path, stderr_to_stdout: true)

    result =
      case exit_code do
        0 -> {:ok, output}
        # no matches: treat as an ok result with no output
        1 -> {:ok, ""}
        _ -> {:error, output}
      end

    result
    |> map_ok(&parse_output(&1, input.path))
    |> map_err(&normalize_rg_error/1)
    |> on_err(fn reason -> Logger.warning("grep failed: " <> reason) end)
  end

  # ripgrep's --json output is newline-delimited JSON events; only "match"
  # events carry a result, the rest ("begin"/"end"/"summary") are ignored.
  # rg runs with cwd set to the subdirectory being searched, so its reported
  # paths are relative to that subdirectory; prefix them back onto `prefix`
  # (the subpath from the worktree root) so results stay root-relative.
  defp parse_output("", _prefix) do
    %{matches: [], truncated?: false}
  end

  defp parse_output(output, prefix) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_match(&1, prefix))
      |> Enum.take(@max_results)

    %{matches: matches, truncated?: length(matches) == @max_results}
  end

  defp decode_match(line, prefix) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        relative = String.trim_leading(data["path"]["text"], "./")

        [
          %{
            path: Path.join(prefix, relative),
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
