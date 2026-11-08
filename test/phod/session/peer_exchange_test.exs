defmodule Phod.Session.PeerExchangeTest do
  use ExUnit.Case, async: true


  alias Phod.Session

  # Two sessions on fresh worktrees, connected mutually. Each test allows them
  # to use the LLM stub once it has defined it (see `allow_llm/1`).
  setup do
    a = fresh_session()
    b = fresh_session()
    :ok = Session.connect(a.id, b.id)
    on_exit(fn -> Session.disconnect(a.id, b.id) end)
    %{a: a, b: b}
  end

  defp fresh_session(description \\ nil) do
    tree = "px-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    if description, do: File.write!(Path.join(root, "DESCRIPTION.md"), description)
    {:ok, pid} = Session.ensure_started("tester", tree)
    %{id: Session.session_id("tester", tree), root: root, pid: pid}
  end

  defp allow_llm(sessions) do
    for %{pid: pid} <- sessions, do: Req.Test.allow(Phod.Session.LlmStub, self(), pid)
  end

  defp body_text(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.encode!(Jason.decode!(raw)["messages"]), conn}
  end

  defp respond(conn, content, stop_reason) do
    Req.Test.json(conn, %{"content" => content, "stop_reason" => stop_reason})
  end

  test "send with want_reply: the peer replies and the sender's run continues to the end",
       %{a: a, b: b} do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      {texts, conn} = body_text(conn)

      cond do
        String.contains?(texts, "Reply from #{b.id}") ->
          respond(conn, [%{"type" => "text", "text" => "done"}], "end_turn")

        String.contains?(texts, "tool_result") ->
          respond(conn, [%{"type" => "text", "text" => "waiting"}], "end_turn")

        String.contains?(texts, "Message from peer ") ->
          respond(
            conn,
            [
              %{
                "type" => "tool_use",
                "id" => "tu_reply",
                "name" => "reply",
                "input" => %{"text" => "b-answer", "goal" => "answer a"}
              }
            ],
            "tool_use"
          )

        String.contains?(texts, "ask b") ->
          respond(
            conn,
            [
              %{
                "type" => "tool_use",
                "id" => "tu_send",
                "name" => "send",
                "input" => %{
                  "peer" => b.id,
                  "prompt" => "answer please",
                  "want_reply" => true,
                  "goal" => "ask b"
                }
              }
            ],
            "tool_use"
          )
      end
    end)

    allow_llm([a, b])
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{a.id}")
    assert :ok = Session.send_message(a.id, "ask b", "Ada")

    # the connection's own snapshot can arrive first, with no messages yet
    assert_receive {:session_snapshot, %{status: :idle, messages: [_ | _] = messages, senders: senders}},
                   5_000

    assert %{"content" => [%{"text" => "done"}]} = List.last(messages)
    assert Enum.any?(Map.values(senders), &(&1 == "reply from #{b.id}"))

    # b ran in peer mode, with the sender shown, and went back to idle
    assert %{status: :idle, senders: %{0 => "peer " <> _}} = Session.get_snapshot(b.id)
  end

  test "a peer message to a busy session queues, and says so", %{b: b, a: a} do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      send(test_pid, :llm_called)
      receive do: (:release -> :ok)
      respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn")
    end)

    allow_llm([b])
    assert :ok = Session.send_message(b.id, "first", "Ada")
    assert_receive :llm_called, 1_000

    assert {:ok, :queued} = Session.deliver(b.id, a.id, "second", false)
    assert %{queued: ["Message from peer " <> _]} = Session.get_snapshot(b.id)

    for child <- Task.Supervisor.children(Phod.Session.TaskSupervisor), do: send(child, :release)
  end

  test "a reply with no run waiting starts a run in user mode", %{a: a, b: b} do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      respond(conn, [%{"type" => "text", "text" => "noted"}], "end_turn")
    end)

    allow_llm([a])
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{a.id}")
    assert {:ok, :started} = Session.deliver_reply(a.id, b.id, "late answer")

    assert_receive {:session_snapshot, %{status: :idle, senders: senders}} when map_size(senders) > 0,
                   2_000

    assert Enum.any?(Map.values(senders), &(&1 == "reply from #{b.id}"))
  end

  test "a one-way connection only carries messages in its direction" do
    x = fresh_session()
    y = fresh_session()
    :ok = Session.connect(x.id, y.id, mode: :one_way)
    on_exit(fn -> Session.disconnect(x.id, y.id) end)

    allow_llm([x, y])
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn")
    end)

    assert {:error, :not_connected} = Session.deliver(x.id, y.id, "backwards", false)
    assert {:ok, :started} = Session.deliver(y.id, x.id, "forwards", false)
  end

  test "delivering to a session that isn't running is an error", %{a: a} do
    missing = "tester/no-such-session"
    assert {:error, {:not_found, ^missing}} = Session.deliver(missing, a.id, "hi", false)
    assert {:error, {:not_found, ^missing}} = Session.deliver_reply(missing, a.id, "hi")
  end

  test "worktrees/1 gives the session's single worktree", %{a: a} do
    assert {:ok, [{id, root}]} = Session.worktrees(a.id)
    assert id == a.id
    assert root == a.root
  end

  describe "DESCRIPTION.md" do
    test "a session's description is the start of its DESCRIPTION.md, capped" do
      long = String.duplicate("x", 1_000)
      s = fresh_session("  " <> long <> "  ")

      assert {:ok, description} = Session.describe(s.id)
      assert String.length(description) == 500
    end

    test "a session with no DESCRIPTION.md has no description" do
      s = fresh_session()
      assert {:ok, nil} = Session.describe(s.id)
    end

    test "a peer's description appears in the peer choices the model sees" do
      b = fresh_session("Hosted game server. Owns the tables.")
      c = fresh_session()
      :ok = Session.connect(c.id, b.id, mode: :one_way)
      on_exit(fn -> Session.disconnect(c.id, b.id) end)

      test_pid = self()

      Req.Test.stub(Phod.Session.LlmStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:tools, Jason.decode!(raw)["tools"]})
        respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn")
      end)

      allow_llm([c])
      assert :ok = Session.send_message(c.id, "hi", "Ada")

      assert_receive {:tools, tools}, 2_000
      send_spec = Enum.find(tools, &(&1["name"] == "send"))
      peer = send_spec["input_schema"]["properties"]["peer"]

      assert peer["enum"] == [b.id]
      assert peer["description"] =~ "- #{b.id}: Hosted game server. Owns the tables."
    end
  end
end
