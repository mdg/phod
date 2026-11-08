defmodule Phod.Session.Loop do
  @moduledoc """
  One agent run: call the LLM, execute the tools it asks for against the
  session's worktree, feed the results back, and repeat until the model stops
  asking for tools (or the round safety valve trips).

  A run has a mode:

    * `:user` — started by the session's user. It has every worktree tool, and,
      if the session has peers, `send` and the read-only tools' `peer` option.
    * `:peer` — started by a message from a peer. It has every worktree tool and
      `reply`, but no `send` and no `peer` option. Calling `reply` ends the run.

  A `send` with `want_reply` makes the run wait for the peer's reply before it
  finishes. Replies that arrive during the run are added to the conversation.

  The peer-facing work (sending, replying, reading a peer's worktree) goes
  through a `:peer` function in the options, which the session provides. This
  module doesn't call other sessions itself.

  Takes no GenServer/Task dependency, so it can be driven directly in tests
  against a real tmp worktree.
  """

  import Rexult

  alias Phod.Session.Llm
  alias Phod.Tool
  alias Phod.Tool.{Input, Reply, Send}

  @type event ::
          {:message_appended, map()}
          | {:edit_recorded, map()}
          | {:peer_input, String.t(), map()}
  @type on_event :: (event() -> any())

  @default_max_rounds 25
  @default_await_timeout_ms 120_000

  @goal_error "goal is required: a one-line description of what this call is for"
  @not_run_reason "not run: the tool round limit for this request has been reached"
  @wrap_up "You have used every tool round for this request, so no more tool calls " <>
             "will run. Summarize what you found, what you changed if anything, and " <>
             "what you propose to do next."

  @doc """
  Runs the loop against the worktree at `root`.

  Options:

    * `:mode` — `:user` (default) or `:peer`
    * `:peers` — the session ids this session may send to
    * `:peer` — also answers `{:describe, peer}` with `{:ok, description | nil}`,
      which a user run shows to the model in its `peer` choices
    * `:peer` — `fn request -> result end` for peer work: `{:send, peer, prompt,
      want_reply}` → `{:ok, %{peer:, status:}}`; `{:reply, text}` → `{:ok, %{to:,
      status:}}`; `{:root, peer}` → `{:ok, root}`
    * `:max_rounds` — tool rounds allowed (default: the `:max_tool_rounds`
      config, 25 when unset)
    * `:await_timeout_ms` — how long to wait for a requested reply

  A bare integer as the fourth argument is taken as `:max_rounds`.
  """
  @spec run([map()], String.t(), on_event(), keyword() | pos_integer() | nil) ::
          {:ok, [map()]} | {:error, {String.t(), [map()]}}
  def run(messages, root, on_event, opts \\ [])

  def run(messages, root, on_event, max_rounds) when not is_list(max_rounds) do
    run(messages, root, on_event, max_rounds: max_rounds)
  end

  def run(messages, root, on_event, opts) do
    mode = Keyword.get(opts, :mode, :user)
    peers = Keyword.get(opts, :peers, [])
    user? = mode == :user
    peer_call = Keyword.get(opts, :peer, &no_peers/1)

    # A user run shows each peer's description to the model; the others don't
    # offer peers, so they don't need it.
    peer_info =
      if user? and peers != [],
        do: Enum.map(peers, &{&1, describe_peer(peer_call, &1)}),
        else: Enum.map(peers, &{&1, nil})

    tools =
      Tool.loop_tools(
        send_to: if(user?, do: peer_info, else: []),
        reply: mode == :peer,
        peer_reads: if(user?, do: peer_info, else: [])
      )

    ctx = %{
      root: root,
      on_event: on_event,
      # read per run, so edits to AGENTS.md apply from the next message on
      instructions: read_instructions(root),
      mode: mode,
      peers: peers,
      call: Keyword.get(opts, :peer, &no_peers/1),
      tools: tools,
      names: MapSet.new(tools, & &1["name"]),
      # peers whose reply this run is still waiting for
      pending: MapSet.new(),
      replied: false,
      await_timeout_ms:
        Keyword.get(
          opts,
          :await_timeout_ms,
          Application.get_env(:phod, :peer_reply_timeout_ms, @default_await_timeout_ms)
        )
    }

    max_rounds =
      Keyword.get(opts, :max_rounds) ||
        Application.get_env(:phod, :max_tool_rounds, @default_max_rounds)

    step(messages, ctx, max_rounds, max_rounds)
  end

  defp no_peers(_request), do: {:error, "this session has no peer connections"}

  # A peer's description, or nil if it can't be had. Called from the run's task,
  # so it doesn't block the session that is running.
  defp describe_peer(peer_call, peer) do
    case peer_call.({:describe, peer}) do
      {:ok, description} -> description
      {:error, _reason} -> nil
    end
  end

  # A missing file means no instructions.
  defp read_instructions(root) do
    case File.read(Path.join(root, "AGENTS.md")) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp step(messages, ctx, remaining, total) do
    {messages, ctx} = flush_replies(messages, ctx)

    case Llm.complete(messages, ctx.instructions, ctx.tools) do
      {:error, reason} ->
        {:error, {reason, messages}}

      {:ok, %{content: blocks, stop_reason: stop_reason}} ->
        assistant_msg = %{"role" => "assistant", "content" => blocks}
        messages = messages ++ [assistant_msg]
        ctx.on_event.({:message_appended, assistant_msg})

        cond do
          stop_reason == "tool_use" ->
            continue_with_tools(messages, ctx, blocks, remaining, total)

          MapSet.size(ctx.pending) > 0 ->
            await_replies(messages, ctx, remaining, total)

          true ->
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

    # A run's error is `{:error, {reason, messages}}` on every path. If the
    # summary request fails, the messages are kept as they were.
    Llm.complete(messages, ctx.instructions, ctx.tools, tool_choice: :none)
    |> on_err(&dbg/1)
    |> map_ok(fn %{content: summary} ->
      summary_msg = %{"role" => "assistant", "content" => summary}
      ctx.on_event.({:message_appended, summary_msg})
      {reason, messages ++ [summary_msg]}
    end)
    |> unwrap_or_else(fn _llm_reason -> {reason, messages} end)
    |> then(&{:error, &1})
  end

  defp continue_with_tools(messages, ctx, blocks, remaining, total) do
    {result_blocks, ctx} =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map_reduce(ctx, &execute_tool/2)

    tool_result_msg = %{"role" => "user", "content" => result_blocks}
    messages = messages ++ [tool_result_msg]
    ctx.on_event.({:message_appended, tool_result_msg})

    # A `:peer` run ends once it has replied.
    if ctx.replied,
      do: {:ok, messages},
      else: step(messages, ctx, remaining - 1, total)
  end

  # Replies ---------------------------------------------------------------

  # A reply that arrived while the run was working: add it to the conversation.
  defp flush_replies(messages, ctx) do
    receive do
      {:peer_reply, from, text} ->
        {messages, ctx} = accept_reply(messages, ctx, from, text)
        flush_replies(messages, ctx)
    after
      0 -> {messages, ctx}
    end
  end

  # The model has finished, but it asked a peer for a reply: wait for it.
  defp await_replies(messages, ctx, remaining, total) do
    receive do
      {:peer_reply, from, text} ->
        {messages, ctx} = accept_reply(messages, ctx, from, text)

        if MapSet.size(ctx.pending) == 0,
          do: step(messages, ctx, remaining, total),
          else: await_replies(messages, ctx, remaining, total)
    after
      ctx.await_timeout_ms ->
        waiting = ctx.pending |> Enum.sort() |> Enum.join(", ")
        notice = user_text("No reply arrived from #{waiting} before the wait timed out.")
        ctx.on_event.({:peer_input, "phod", notice})
        {:ok, messages ++ [notice]}
    end
  end

  defp accept_reply(messages, ctx, from, text) do
    msg = user_text("Reply from #{from}:\n\n#{text}")
    ctx.on_event.({:peer_input, "reply from #{from}", msg})
    {messages ++ [msg], %{ctx | pending: MapSet.delete(ctx.pending, from)}}
  end

  defp user_text(text), do: %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}

  # Tool calls ------------------------------------------------------------

  defp execute_tool(block, ctx) do
    id = Map.get(block, "id")
    name = Map.get(block, "name")
    input = Map.get(block, "input", %{})

    if name && MapSet.member?(ctx.names, name) do
      {result, ctx} = dispatch(name, input, ctx)
      record_edit(name, input, result, ctx)
      {tool_result_block(id, result), ctx}
    else
      {tool_result_block(id, {:error, "unknown tool: #{inspect(name)}"}), ctx}
    end
  end

  defp dispatch(name, input, ctx) do
    cond do
      not goal?(input) -> {{:error, @goal_error}, ctx}
      name == "send" -> run_send(input, ctx)
      name == "reply" -> run_reply(input, ctx)
      Map.has_key?(input, "peer") -> {run_peer_read(name, input, ctx), ctx}
      true -> {Tool.run(name, ctx.root, input), ctx}
    end
  end

  # Every tool call needs a goal: one line saying what the call is for.
  defp goal?(input) do
    case Map.get(input, "goal") do
      goal when is_binary(goal) -> String.trim(goal) != ""
      _missing -> false
    end
  end

  defp run_send(input, ctx) do
    case Input.validate_params(input, Send.params(), %{}) do
      {:ok, args} ->
        result = Send.run(args, %{peers: ctx.peers, call: ctx.call})

        # Only a successful send with want_reply is waited for.
        ctx =
          if match?({:ok, _}, result) and args.want_reply,
            do: %{ctx | pending: MapSet.put(ctx.pending, args.peer)},
            else: ctx

        {result, ctx}

      {:error, _msg} = error ->
        {error, ctx}
    end
  end

  defp run_reply(input, ctx) do
    case Input.validate_params(input, Reply.params(), %{}) do
      {:ok, args} ->
        result = Reply.run(args, %{call: ctx.call})
        {result, %{ctx | replied: match?({:ok, _}, result)}}

      {:error, _msg} = error ->
        {error, ctx}
    end
  end

  # A read-only tool run against a peer's worktree.
  defp run_peer_read(name, input, ctx) do
    peer = Map.get(input, "peer")

    cond do
      ctx.mode != :user -> {:error, "peer worktrees are not available in this run"}
      not Tool.peer_readable?(name) -> {:error, "#{name} can't run in a peer's worktree"}
      peer not in ctx.peers -> {:error, "peer #{inspect(peer)} is not connected to this session"}
      true -> peer_root_then_run(name, peer, input, ctx)
    end
  end

  defp peer_root_then_run(name, peer, input, ctx) do
    case ctx.call.({:root, peer}) do
      {:ok, root} -> Tool.run(name, root, Map.delete(input, "peer"))
      {:error, _reason} = error -> error
    end
  end

  defp tool_result_block(id, {:ok, payload}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => Jason.encode!(payload)}
  end

  defp tool_result_block(id, {:error, reason}) do
    %{"type" => "tool_result", "tool_use_id" => id, "content" => reason, "is_error" => true}
  end

  defp record_edit("patch", _input, {:ok, payload}, ctx) do
    ctx.on_event.(
      {:edit_recorded,
       %{
         path: payload.path,
         applied_hunks: payload.applied_hunks,
         created?: payload.created?,
         at: DateTime.utc_now()
       }}
    )
  end

  defp record_edit(_tool_name, _input, _result, _ctx), do: :ok
end
