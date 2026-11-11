defmodule Phod.Tool.Patch.Hunks do
  @moduledoc """
  Applies the hunks of a diff by matching their text instead of their line
  numbers. This is the last resort for diffs that `patch` cannot apply: wrong
  or missing line numbers, bare `@@` headers, and hunks without `---`/`+++`
  headers.

  A hunk applies where its context and removed lines occur in the file. When
  that text occurs more than once, the match nearest the header's line number
  wins, or the first match after the previous hunk when there is no number.
  Matching is exact first and ignores surrounding whitespace only if nothing
  matches exactly.
  """

  import Rexult

  @hunk_header ~r/^@@ -(\d+)(?:,\d+)? /

  @type hunk :: %{index: non_neg_integer() | nil, old: [String.t()], new: [String.t()]}

  @doc """
  Parses the hunks in a diff.

  Lines before the first `@@` are ignored, as are `***` envelope lines and
  `\\` "no newline" markers. A line without a diff prefix is read as a context
  line, because models often drop the leading space of context lines.
  """
  @spec parse(String.t()) :: {:ok, [hunk()]} | {:error, String.t()}
  def parse(diff) do
    diff
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> hunks([])
    |> case do
      [] -> {:error, "no hunks found: each hunk starts with an @@ line"}
      hunks -> {:ok, hunks}
    end
  end

  @doc """
  Applies hunks to file content, returning the new content.

  The content is returned unchanged in its final-newline state: a file that
  ended with a newline still does, and one that did not still does not.
  """
  @spec apply_hunks(String.t(), [hunk()]) :: {:ok, String.t()} | {:error, String.t()}
  def apply_hunks(content, hunks) do
    {lines, final_newline?} = split_content(content)

    hunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{lines: lines, cursor: 0, shift: 0}}, fn {hunk, n}, {:ok, state} ->
      case place(state, hunk) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, "hunk #{n} #{reason}"}}
      end
    end)
    |> ok_and_then(fn %{lines: lines} -> {:ok, join_content(lines, final_newline?)} end)
  end

  defp hunks([], acc), do: Enum.reverse(acc)

  defp hunks([header | rest], acc) do
    {body, remaining} = Enum.split_while(rest, &(not String.starts_with?(&1, "@@")))
    hunks(remaining, [build(header, body) | acc])
  end

  defp build(header, body) do
    lines =
      body
      |> Enum.reject(&String.starts_with?(&1, ["***", "\\"]))
      |> Enum.map(&parse_line/1)
      |> drop_trailing_blank_context()

    old = for {kind, text} <- lines, kind != :new, do: text

    %{
      index: header_index(header, old),
      old: old,
      new: for({kind, text} <- lines, kind != :old, do: text)
    }
  end

  defp parse_line(" " <> text), do: {:context, text}
  defp parse_line("+" <> text), do: {:new, text}
  defp parse_line("-" <> text), do: {:old, text}
  defp parse_line(line), do: {:context, line}

  # A blank context line at the end of a hunk is usually the empty line
  # after the diff, or a context line whose trailing space was stripped.
  # Dropping it from both sides keeps the hunk consistent.
  defp drop_trailing_blank_context(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(fn {kind, text} -> kind == :context and String.trim(text) == "" end)
    |> Enum.reverse()
  end

  # Returns the 0-based line where the hunk's old side should start. A pure
  # insertion ("-N,0") goes after line N, so its index is N itself.
  defp header_index(header, old) do
    case Regex.run(@hunk_header, header, capture: :all_but_first) do
      [start] -> start_index(String.to_integer(start), old)
      nil -> nil
    end
  end

  defp start_index(start, []), do: start
  defp start_index(start, _old), do: max(start - 1, 0)

  defp place(%{lines: lines} = state, %{old: []} = hunk) do
    at = min(hint(hunk, state), length(lines))
    {:ok, put(state, at, 0, hunk)}
  end

  defp place(state, hunk) do
    case find(state.lines, hunk.old, state.cursor, hint(hunk, state)) do
      {:ok, at} ->
        {:ok, put(state, at, length(hunk.old), hunk)}

      :error ->
        {:error,
         "could not find its context in the file; expected a line like #{inspect(hd(hunk.old))}"}
    end
  end

  defp hint(%{index: nil}, %{cursor: cursor}), do: cursor
  defp hint(%{index: index}, %{shift: shift}), do: index + shift

  defp put(state, at, removed, hunk) do
    lines = state.lines

    %{
      state
      | lines: Enum.take(lines, at) ++ hunk.new ++ Enum.drop(lines, at + removed),
        cursor: at + length(hunk.new),
        shift: state.shift + length(hunk.new) - removed
    }
  end

  defp find(lines, old, cursor, hint) do
    width = length(old)
    starts = 0..(length(lines) - width)//1

    exact = Enum.filter(starts, &(Enum.slice(lines, &1, width) == old))
    loose = Enum.filter(starts, &(trimmed(Enum.slice(lines, &1, width)) == trimmed(old)))

    nearest(if(exact == [], do: loose, else: exact), cursor, hint)
  end

  defp nearest([], _cursor, _hint), do: :error

  defp nearest(candidates, cursor, hint) do
    after_cursor = Enum.filter(candidates, &(&1 >= cursor))
    pool = if after_cursor == [], do: candidates, else: after_cursor

    {:ok, Enum.min_by(pool, &abs(&1 - hint))}
  end

  defp trimmed(lines), do: Enum.map(lines, &String.trim/1)

  defp split_content(""), do: {[], true}

  defp split_content(content) do
    if String.ends_with?(content, "\n") do
      {content |> String.split("\n") |> Enum.drop(-1), true}
    else
      {String.split(content, "\n"), false}
    end
  end

  defp join_content([], _final_newline?), do: ""

  defp join_content(lines, final_newline?) do
    Enum.join(lines, "\n") <> if(final_newline?, do: "\n", else: "")
  end
end
