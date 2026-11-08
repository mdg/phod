defmodule PhodWeb.SessionLive.Transcript do
  @moduledoc """
  Pure transformation of `Phod.Session`'s raw Anthropic-Messages-shaped
  message list into a flat list of renderable transcript items, plus the
  "files touched by the most recent run" tracking used to highlight the file
  tree and editor pane.

  Kept free of any LiveView/Phoenix dependency so it's unit-testable on its
  own.
  """

  @type item ::
          %{kind: :text, role: String.t(), text: String.t()}
          | %{
              kind: :tool_call,
              id: String.t(),
              name: String.t(),
              input: map(),
              result: result(),
            }

  @type result :: {:ok, map()} | {:error, String.t()} | :pending

  @doc """
  Flattens `messages` into transcript items: assistant text and tool-use
  blocks become items directly; each tool-use block's result is looked up
  by id from any matching `tool_result` block anywhere in `messages` (found
  via `Jason.decode!`-ing its `content` string on success — error content is
  already a plain string, per `Phod.Session.Loop.tool_result_block/2`).
  User messages are only rendered when every block is plain text; a user
  message carrying `tool_result` blocks is the loop's internal hand-back to
  the LLM and is already represented via the pairing above.
  """
  @spec build([map()]) :: [item()]
  def build(messages) do
    results = index_tool_results(messages)
    Enum.flat_map(messages, &message_items(&1, results))
  end

  @doc """
  Returns the updated edit marker (an index into the edits list) for a
  `prev_status -> new_status` transition. The marker advances only on the
  idle-to-running rising edge, pinning the boundary before the run's own
  edits exist yet.
  """
  @spec advance_edit_marker(atom(), atom(), non_neg_integer(), [map()]) :: non_neg_integer()
  def advance_edit_marker(:idle, :running, _marker, edits), do: length(edits)
  def advance_edit_marker(_prev_status, _new_status, marker, _edits), do: marker

  @doc """
  The distinct file paths edited at or after `marker` in `edits`.
  """
  @spec recent_edit_paths([map()], non_neg_integer()) :: [String.t()]
  def recent_edit_paths(edits, marker) do
    edits
    |> Enum.drop(marker)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
  end

  defp index_tool_results(messages) do
    messages
    |> Enum.flat_map(fn %{"content" => blocks} -> blocks end)
    |> Enum.filter(&(&1["type"] == "tool_result"))
    |> Map.new(fn block -> {block["tool_use_id"], decode_result(block)} end)
  end

  defp decode_result(%{"is_error" => true, "content" => content}), do: {:error, content}

  defp decode_result(%{"content" => content}) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, content}
    end
  end

  # A tool call's goal is shown as a Phod message just above the call.
  defp goal_items(%{"goal" => goal}) when is_binary(goal) do
    if String.trim(goal) == "", do: [], else: [%{kind: :text, role: "phod", text: goal}]
  end

  defp goal_items(_input), do: []

  defp message_items(%{"role" => "assistant", "content" => blocks}, results) do
    Enum.flat_map(blocks, fn
      %{"type" => "text", "text" => text} ->
        [%{kind: :text, role: "assistant", text: text}]

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        goal_items(input) ++
          [
            %{
              kind: :tool_call,
              id: id,
              name: name,
              input: input,
              result: Map.get(results, id, :pending),
            },
          ]

      _other ->
        []
    end)
  end

  defp message_items(%{"role" => "user", "content" => blocks}, _results) do
    if Enum.all?(blocks, &(&1["type"] == "text")) do
      Enum.map(blocks, fn %{"text" => text} -> %{kind: :text, role: "user", text: text} end)
    else
      []
    end
  end

  defp message_items(_other, _results), do: []
end
