defmodule Phod.Tool.ApplyDiff do
  @moduledoc false

  alias Phod.Tool

  # Applies a unified diff to a single file, atomically: all hunks are matched
  # against the in-memory file content first, and nothing is written unless
  # every hunk applies successfully.

  @behaviour Tool.B

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  @impl Tool.B
  def name, do: :apply_diff

  @impl Tool.B
  def description,
    do: """
    Apply a unified diff to one file in the worktree. Provide the diff in \
    standard format with one or more `@@ -l,c +l,c @@` hunks. Context lines and \
    line numbers must match the current file contents; the whole apply is \
    atomic - if any hunk fails, nothing is written. To create a new file, use a \
    diff against /dev/null. After applying, verify the result with read_file.\
    """

  @impl Tool.B
  def tool_fields() do
    [:allow_new_path, :path, :diff]
  end

  @impl Tool.B
  def run(%Tool.Input{full_path: full_path, path: path, diff: diff}) do
    with {:ok, lines, trailing_newline?} <- read_lines(full_path),
         {:ok, hunks} <- parse_hunks(diff) do
      apply_hunks(full_path, path, lines, trailing_newline?, hunks)
    end
  end

  defp read_lines(absolute) do
    if File.exists?(absolute) do
      case Tool.Lib.read_lines(absolute) do
        {:ok, lines, trailing?} ->
          {:ok, lines, trailing?}

        {:error, reason} ->
          {:error, "could not read file: " <> Tool.Lib.format_error(reason)}
      end
    else
      {:ok, [], false}
    end
  end

  # Diff parsing -------------------------------------------------------------

  defp parse_hunks(diff) do
    case diff |> String.split("\n") |> collect_hunks([]) do
      {:error, reason} ->
        {:error, reason}

      hunks when hunks == [] ->
        {:error, "no unified diff hunks (`@@ -l,c +l,c @@`) found in diff"}

      hunks ->
        {:ok, Enum.reverse(hunks)}
    end
  end

  defp collect_hunks([line | rest], hunks) do
    case Regex.run(@hunk_header, String.trim_trailing(line)) do
      [header, old_start, old_count_or_empty, new_start | _] ->
        case collect_actions(rest, header, []) do
          {:ok, actions, rest} ->
            hunk = %{
              old_start: String.to_integer(old_start),
              old_count: parse_count(old_count_or_empty),
              new_start: String.to_integer(new_start),
              actions: Enum.reverse(actions)
            }

            collect_hunks(rest, [hunk | hunks])

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        collect_hunks(rest, hunks)
    end
  end

  defp collect_hunks([], hunks), do: hunks

  defp collect_actions([line | rest], header, actions) do
    trimmed = String.trim_trailing(line)

    cond do
      String.starts_with?(trimmed, "@@") ->
        # start of the next hunk: stop consuming this one
        {:ok, actions, [line | rest]}

      trimmed == "" ->
        # a bare empty line (typically the artifact of a trailing newline in
        # the diff itself) carries no action; genuine empty context lines are
        # prefixed with a space
        collect_actions(rest, header, actions)

      String.starts_with?(trimmed, " ") ->
        collect_actions(rest, header, [{:ctx, String.slice(trimmed, 1..-1//1)} | actions])

      String.starts_with?(trimmed, "+") ->
        collect_actions(rest, header, [{:add, String.slice(trimmed, 1..-1//1)} | actions])

      String.starts_with?(trimmed, "-") ->
        collect_actions(rest, header, [{:del, String.slice(trimmed, 1..-1//1)} | actions])

      String.starts_with?(trimmed, "\\") ->
        # "\ No newline at end of file" — ignore
        collect_actions(rest, header, actions)

      String.starts_with?(trimmed, "diff ") or String.starts_with?(trimmed, "index ") or
        String.starts_with?(trimmed, "--- ") or String.starts_with?(trimmed, "+++ ") or
          String.starts_with?(trimmed, "new file mode") ->
        # file headers between hunks — ignore
        collect_actions(rest, header, actions)

      true ->
        {:error,
         "invalid diff: unexpected line following #{inspect(header)}: #{inspect(trimmed)}"}
    end
  end

  defp collect_actions([], _header, actions), do: {:ok, actions, []}

  defp parse_count(""), do: 1
  defp parse_count(count), do: String.to_integer(count)

  # Application --------------------------------------------------------------

  defp apply_hunks(absolute, path, lines, trailing_newline?, hunks) do
    created? = not File.exists?(absolute)

    case do_apply(Enum.with_index(hunks, 1), 0, lines) do
      {:ok, result} ->
        File.mkdir_p!(Path.dirname(absolute))
        Tool.Lib.write_lines(absolute, result, trailing_newline? or created?)

        {:ok, %{path: path, applied_hunks: length(hunks), created?: created?}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_apply([{hunk, n} | tail], offset, lines) do
    old_block = old_block(hunk.actions)

    location =
      cond do
        # an empty old block is an insertion — trust the header position
        old_block == [] and hunk.old_count == 0 ->
          start = max(0, hunk.old_start - 1 + offset)

          if start <= length(lines), do: {:ok, start}, else: :not_found

        true ->
          expected = max(0, hunk.old_start - 1 + offset)

          if slice_matches?(lines, expected, old_block) do
            {:ok, expected}
          else
            find_elsewhere(lines, old_block, expected)
          end
      end

    case location do
      {:ok, start} ->
        new_block = new_block(hunk.actions)
        replaced = replace_slice(lines, start, old_block, new_block)
        do_apply(tail, offset + length(new_block) - length(old_block), replaced)

      :not_found ->
        {:error,
         "hunk ##{n}: context mismatch - could not find expected block near line " <>
           "#{hunk.old_start}. Re-read the file and try again."}
    end
  end

  defp do_apply([], _offset, lines), do: {:ok, lines}

  defp old_block(actions), do: for({type, line} <- actions, type in [:ctx, :del], do: line)
  defp new_block(actions), do: for({type, line} <- actions, type in [:ctx, :add], do: line)

  defp slice_matches?(lines, start, old_block) do
    start >= 0 and
      length(lines) >= start + length(old_block) and
      Enum.slice(lines, start, length(old_block)) == old_block
  end

  defp find_elsewhere(lines, old_block, expected) do
    count = length(lines)

    candidates =
      if count >= length(old_block) do
        for(i <- Range.new(0, count - length(old_block), 1), i != expected, do: i)
      else
        []
      end

    case Enum.find(candidates, &slice_matches?(lines, &1, old_block)) do
      nil -> :not_found
      start -> {:ok, start}
    end
  end

  defp replace_slice(lines, start, old_block, new_block) do
    {prefix, suffix} = Enum.split(lines, start)
    prefix ++ new_block ++ Enum.drop(suffix, length(old_block))
  end
end
