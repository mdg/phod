defmodule Phod.Session.Loop do
  @moduledoc """
  The agent's tool-calling loop: call the LLM, execute any requested tools
  against the sandboxed worktree, feed results back, and repeat until the
  model stops asking for tools (or the round safety valve trips).

  Takes no GenServer/Task dependency, so it can be driven directly in
  tests against a real tmp worktree.
  """

  alias Phod.Session.Llm

  @type event :: {:message_appended, map()} | {:edit_recorded, map()}
  @type on_event :: (event() -> any())

  @default_max_rounds 25

  @spec run([map()], String.t(), on_event(), pos_integer()) ::
          {:ok, [map()]} | {:error, String.t(), [map()]}
  def run(messages, root, on_event, max_rounds \\ @default_max_rounds) do
    step(messages, root, on_event, max_rounds, max_rounds)
  end

  defp step(messages, root, on_event, remaining, total) do
    case Llm.complete(messages) do
      {:error, reason} ->
        {:error, reason, messages}

      {:ok, %{content: blocks, stop_reason: stop_reason}} ->
        assistant_msg = %{"role" => "assistant", "content" => blocks}
        messages = messages ++ [assistant_msg]
        on_event.({:message_appended, assistant_msg})

        if stop_reason == "tool_use" do
          continue_with_tools(messages, root, on_event, blocks, remaining, total)
        else
          {:ok, messages}
        end
    end
  end

  defp continue_with_tools(messages, _root, _on_event, _blocks, remaining, total)
       when remaining <= 0 do
    {:error, "tool loop exceeded max rounds (#{total})", messages}
  end

  defp continue_with_tools(messages, root, on_event, blocks, remaining, total) do
    result_blocks =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&execute_tool(&1, root, on_event))

    tool_result_msg = %{"role" => "user", "content" => result_blocks}
    messages = messages ++ [tool_result_msg]
    on_event.({:message_appended, tool_result_msg})

    step(messages, root, on_event, remaining - 1, total)
  end

  defp execute_tool(block, root, on_event) do
    id = Map.get(block, "id")
    name = Map.get(block, "name")
    input = Map.get(block, "input", %{})

    case name && Phod.Tool.fetch_name(name) do
      {:ok, tool_name} ->
        result = Phod.Tool.run(tool_name, root, input)
        record_edit(tool_name, result, on_event)
        tool_result_block(id, result)

      _ ->
        tool_result_block(id, {:error, "unknown tool: #{inspect(name)}"})
    end
  end

  defp tool_result_block(id, {:ok, payload}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => Jason.encode!(payload)}
  end

  defp tool_result_block(id, {:error, reason}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => reason, "is_error" => true}
  end

  defp record_edit(:apply_diff, {:ok, payload}, on_event) do
    on_event.(
      {:edit_recorded,
       %{
         path: payload.path,
         applied_hunks: payload.applied_hunks,
         created?: payload.created?,
         at: DateTime.utc_now()
       }}
    )
  end

  defp record_edit(_tool_name, _result, _on_event), do: :ok
end
