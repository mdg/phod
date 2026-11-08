defmodule Phod.Session.LoopPeerTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Session.Loop
  alias Phod.Tool

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  defp tool_use(id, name, input) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => Map.put(input, "goal", "test")}
  end

  defp respond_with(conn, content, stop_reason) do
    Req.Test.json(conn, %{"content" => content, "stop_reason" => stop_reason})
  end

  defp user_message(text), do: %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}

  defp names(tools), do: Enum.map(tools, & &1["name"])

  defp collect_events do
    pid = self()
    {fn event -> send(pid, {:event, event}) end, fn -> drain([]) end}
  end

  defp drain(acc) do
    receive do
      {:event, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "tools offered per run" do
    test "a user run with peers offers send, with the peers as its choices" do
      tools = Tool.loop_tools(send_to: ["a/x", "a/y"], reply: false, peer_reads: ["a/x"])

      assert "send" in names(tools)
      refute "reply" in names(tools)

      send_spec = Enum.find(tools, &(&1["name"] == "send"))
      assert send_spec["input_schema"]["properties"]["peer"]["enum"] == ["a/x", "a/y"]
    end

    test "a peer run offers reply and no send" do
      tools = Tool.loop_tools(send_to: [], reply: true, peer_reads: [])

      assert "reply" in names(tools)
      refute "send" in names(tools)
    end

    test "only read-only tools take a peer option, and only when there are peers" do
      with_peers = Tool.loop_tools(send_to: ["a/x"], reply: false, peer_reads: ["a/x"])
      without = Tool.loop_tools(send_to: [], reply: false, peer_reads: [])

      read_with = Enum.find(with_peers, &(&1["name"] == "grep"))
      assert read_with["input_schema"]["properties"]["peer"]["enum"] == ["a/x"]

      write_with = Enum.find(with_peers, &(&1["name"] == "write_file"))
      refute Map.has_key?(write_with["input_schema"]["properties"], "peer")

      read_without = Enum.find(without, &(&1["name"] == "grep"))
      refute Map.has_key?(read_without["input_schema"]["properties"], "peer")
    end

    test "every offered tool requires a goal" do
      for tool <- Tool.loop_tools(send_to: ["a/x"], reply: true, peer_reads: []) do
        assert "goal" in tool["input_schema"]["required"]
      end
    end
  end

  test "a peer run can't call send: it is an unknown tool", %{root: root} do
    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "send", %{"peer" => "a/x", "prompt" => "hi"})], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond_with(conn, [%{"type" => "text", "text" => "ok"}], "end_turn") end)

    {on_event, events} = collect_events()

    assert {:ok, _} =
             Loop.run([user_message("hi")], root, on_event, mode: :peer, peers: [], peer: fn _ -> {:ok, %{}} end)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["is_error"] == true
    assert result["content"] =~ "unknown tool"
  end

  test "reply sends the answer to the sender and ends a peer run", %{root: root} do
    test_pid = self()

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "reply", %{"text" => "the answer"})], "tool_use")
    end)

    # no further request should be made after the reply
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      send(test_pid, :unexpected_request)
      respond_with(conn, [%{"type" => "text", "text" => "more"}], "end_turn")
    end)

    peer = fn
      {:reply, text} -> send(test_pid, {:replied, text}); {:ok, %{to: "a/x", status: :started}}
    end

    assert {:ok, _messages} =
             Loop.run([user_message("question")], root, fn _ -> :ok end, mode: :peer, peer: peer)

    assert_received {:replied, "the answer"}
    refute_received :unexpected_request
  end

  test "a send that wants a reply waits for it before the run finishes", %{root: root} do
    test_pid = self()

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "send", %{"peer" => "a/b", "prompt" => "please check", "want_reply" => true})], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      send(test_pid, :second_request)
      respond_with(conn, [%{"type" => "text", "text" => "waiting for b"}], "end_turn")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [%{"type" => "text", "text" => "b says yes"}], "end_turn")
    end)

    peer = fn
      {:send, "a/b", "please check", true} ->
        send(test_pid, :sent)
        {:ok, %{peer: "a/b", status: :started}}
    end

    task =
      Task.async(fn ->
        receive do: (:go -> :ok)
        Loop.run([user_message("ask b")], root, fn _ -> :ok end, mode: :user, peers: ["a/b"], peer: peer)
      end)

    Req.Test.allow(Phod.Session.LlmStub, self(), task.pid)
    send(task.pid, :go)

    assert_receive :sent, 1000
    # the reply comes once the model has stopped, so the run must wait for it
    assert_receive :second_request, 1000
    send(task.pid, {:peer_reply, "a/b", "yes"})

    assert {:ok, messages} = Task.await(task, 2000)
    assert %{"role" => "user", "content" => [%{"text" => "Reply from a/b:\n\nyes"}]} =
             Enum.find(messages, &match?(%{"content" => [%{"text" => "Reply from a/b:\n\nyes"}]}, &1))

    assert List.last(messages)["content"] == [%{"type" => "text", "text" => "b says yes"}]
  end

  test "a wait for a reply that never comes ends the run with a notice", %{root: root} do
    test_pid = self()

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "send", %{"peer" => "a/b", "prompt" => "check", "want_reply" => true})], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [%{"type" => "text", "text" => "waiting"}], "end_turn")
    end)

    peer = fn {:send, _, _, _} -> {:ok, %{peer: "a/b", status: :started}} end
    {on_event, _events} = collect_events()

    assert {:ok, messages} =
             Loop.run([user_message("ask")], root, fn e -> send(test_pid, {:event, e}); on_event.(e) end,
               mode: :user,
               peers: ["a/b"],
               peer: peer,
               await_timeout_ms: 50
             )

    assert %{"content" => [%{"text" => notice}]} = List.last(messages)
    assert notice =~ "No reply arrived from a/b"
    assert_received {:event, {:peer_input, "phod", _}}
  end

  test "a read-only tool runs in the peer's worktree when asked", %{root: root} do
    peer_root = Path.join(System.tmp_dir!(), "peer-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(peer_root)
    on_exit(fn -> File.rm_rf!(peer_root) end)
    write(peer_root, "theirs.txt", "from the peer\n")

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "read_files", %{"paths" => ["theirs.txt"], "peer" => "a/b"})], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond_with(conn, [%{"type" => "text", "text" => "ok"}], "end_turn") end)

    {on_event, events} = collect_events()
    peer = fn {:root, "a/b"} -> {:ok, peer_root} end

    assert {:ok, _} = Loop.run([user_message("read")], root, on_event, mode: :user, peers: ["a/b"], peer: peer)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["content"] =~ "from the peer"
  end

  test "a write tool can't take a peer option", %{root: root} do
    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond_with(conn, [tool_use("tu_1", "write_file", %{"path" => "x.txt", "content" => "x", "peer" => "a/b"})], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond_with(conn, [%{"type" => "text", "text" => "ok"}], "end_turn") end)

    {on_event, events} = collect_events()
    assert {:ok, _} = Loop.run([user_message("write")], root, on_event, mode: :user, peers: ["a/b"], peer: fn _ -> {:ok, "x"} end)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["is_error"] == true
    assert result["content"] =~ "can't run in a peer's worktree"
    refute File.exists?(Path.join(root, "x.txt"))
  end
end
