defmodule Phod.Session.Loop do
  @moduledoc """
  The agent's tool-calling loop: call the LLM, execute any requested tools
  against the session's worktrees, feed results back, and repeat until the
  model stops asking for tools (or the round safety valve trips).

  Takes no GenServer/Task dependency, so it can be driven directly in
  tests against a real tmp worktree.
  """

  alias Phod.Session.Llm
  alias Phod.Tool

  @type event :: {:message_appended, map()} | {:edit_recorded, map()}
  @type on_event :: (event() -> any())

  @default_max_rounds 25

  @not_run_reason "not run: the tool round limit for this request has been reached"
  @wrap_up "You have used every tool round for this request, so no more tool calls " <>
             "will run. Summarize what you found, what you changed if anything, and " <>
             "what you propose to do next."

  @doc """
  Runs the loop. `worktrees` is the session's `[{name, root}]`, primary first;
  a single root path is accepted as one unnamed worktree. `max_rounds` caps the
  tool rounds in this run; by default it is the `:max_tool_rounds` config
  value (25 when unset).
  """
  @spec run([map()], [{String.t(), String.t()}] | String.t(), on_event(), pos_integer() | nil) ::
          {:ok, [map()]} | {:error, String.t(), [map()]}
  def run(messages, worktrees, on_event, max_rounds \\ nil) do
    max_rounds = max_rounds || Application.get_env(:phod, :max_tool_rounds, @default_max_rounds)
    worktrees = normalize_worktrees(worktrees)
    {_primary, primary_root} = hd(worktrees)

    ctx = %{
      worktrees: worktrees,
      on_event: on_event,
      # read per run, so edits to AGENTS.md apply from the next message on
      instructions: read_instructions(primary_root),
      tools: Tool.anthropic_tools(Enum.map(worktrees, &elem(&1, 0)))
    }

    step(messages, ctx, max_rounds, max_rounds)
  end

  defp normalize_worktrees(root) when is_binary(root), do: [{"default", root}]
  defp normalize_worktrees(worktrees) when is_list(worktrees), do: worktrees

  # A missing file means no instructions.
  defp read_instructions(root) do
    case File.read(Path.join(root, "AGENTS.md")) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp step(messages, ctx, remaining, total) do
    case Llm.complete(messages, ctx.instructions, ctx.tools) do
      {:error, reason} ->
        {:error, reason, messages}

      {:ok, %{content: blocks, stop_reason: stop_reason}} ->
        assistant_msg = %{"role" => "assistant", "content" => blocks}
        messages = messages ++ [assistant_msg]
        ctx.on_event.({:message_appended, assistant_msg})

        if stop_reason == "tool_use" do
          continue_with_tools(messages, ctx, blocks, remaining, total)
        else
          {:ok, messages}
        end
    end
  end

  # Out of rounds: the requested tool calls are answered as not run, so the
  # conversation stays valid, and one more request (with tools disabled) asks
  # the model to report what it found. The run still ends with the error.
  defp continue_with_tools(messages, ctx, blocks, remaining, total)
       when remaining <= 0 do
    reason = "tool loop exceeded max rounds (#{total})"

    not_run =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&tool_result_block(&1["id"], {:error, @not_run_reason}))

    wrap_up_msg = %{
      "role" => "user",
      "content" => not_run ++ [%{"type" => "text", "text" => @wrap_up}]
    }

    messages = messages ++ [wrap_up_msg]
    ctx.on_event.({:message_appended, wrap_up_msg})

    case Llm.complete(messages, ctx.instructions, ctx.tools, tool_choice: :none) do
      {:ok, %{content: summary}} ->
        summary_msg = %{"role" => "assistant", "content" => summary}
        ctx.on_event.({:message_appended, summary_msg})
        {:error, reason, messages ++ [summary_msg]}

      {:error, _llm_reason} ->
        {:error, reason, messages}
    end
  end

  defp continue_with_tools(messages, ctx, blocks, remaining, total) do
    result_blocks =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&execute_tool(&1, ctx))

    tool_result_msg = %{"role" => "user", "content" => result_blocks}
    messages = messages ++ [tool_result_msg]
    ctx.on_event.({:message_appended, tool_result_msg})

    step(messages, ctx, remaining - 1, total)
  end

  defp execute_tool(block, ctx) do
    id = Map.get(block, "id")
    name = Map.get(block, "name")
    input = Map.get(block, "input", %{})

    if name do
      result = Tool.run(name, ctx.worktrees, input)
      record_edit(name, input, result, ctx)
      tool_result_block(id, result)
    else
      tool_result_block(id, {:error, "unknown tool: #{inspect(name)}"})
    end
  end

  defp tool_result_block(id, {:ok, payload}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => Jason.encode!(payload)}
  end

  defp tool_result_block(id, {:error, reason}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => reason, "is_error" => true}
  end

  defp record_edit("patch", input, {:ok, payload}, ctx) do
    {:ok, {worktree, _root}} = Tool.select_worktree(ctx.worktrees, input)

    ctx.on_event.(
      {:edit_recorded,
       %{
         worktree: worktree,
         path: payload.path,
         applied_hunks: payload.applied_hunks,
         created?: payload.created?,
         at: DateTime.utc_now()
       }}
    )
  end

  defp record_edit(_tool_name, _input, _result, _ctx), do: :ok
end
