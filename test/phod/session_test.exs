defmodule Phod.SessionTest do
  use ExUnit.Case, async: true

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  setup do
    %{id: "test-session-#{System.unique_integer([:positive])}"}
  end

  defp text_response(text, stop_reason \\ "end_turn") do
    fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop_reason
      })
    end
  end

  import Phod.Session.TestHelpers, only: [start_and_allow: 2]

  test "send_message/2 runs the loop and settles back to :idle", %{id: id, root: root} do
    Req.Test.expect(Phod.Session.LlmStub, text_response("hello!"))

    pid = start_and_allow(id, root)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "hi")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :running}}, 1000
    assert_receive {:session_snapshot, %{status: :idle, messages: messages}}, 1000
    assert length(messages) == 2
  end

  test "a second send_message/2 while running is rejected with :busy", %{id: id, root: root} do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      send(test_pid, :llm_called)
      receive do: (:release -> :ok)
      Req.Test.json(conn, %{"content" => [], "stop_reason" => "end_turn"})
    end)

    pid = start_and_allow(id, root)

    assert :ok = Phod.Session.send_message(id, "first")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)
    assert_receive :llm_called, 1000

    assert {:error, :busy} = Phod.Session.send_message(id, "second")

    # release the gated stub so the test doesn't leave a hanging process
    for task_child <- Task.Supervisor.children(Phod.Session.TaskSupervisor) do
      send(task_child, :release)
    end
  end

  test "apply_diff round-trips through the GenServer and is visible in get_snapshot/1", %{
    id: id,
    root: root
  } do
    diff = "@@ -0,0 +1,1 @@\n+hello"

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "apply_diff",
            "input" => %{"path" => "new.txt", "diff" => diff}
          }
        ],
        "stop_reason" => "tool_use"
      })
    end)

    Req.Test.expect(Phod.Session.LlmStub, text_response("done"))

    pid = start_and_allow(id, root)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "create new.txt")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :idle, edits: [_ | _]}}, 1000

    snapshot = Phod.Session.get_snapshot(id)
    assert [%{path: "new.txt", created?: true}] = snapshot.edits
    assert File.read!(Path.join(root, "new.txt")) == "hello\n"
  end

  test "ensure_started/2 called twice returns the same pid", %{id: id, root: root} do
    assert {:ok, pid} = Phod.Session.ensure_started(id, root)
    assert {:ok, ^pid} = Phod.Session.ensure_started(id, root)
  end

  test "get_snapshot/1 and send_message/2 report :not_found for an unknown id" do
    assert Phod.Session.get_snapshot("does-not-exist") == {:error, :not_found}
    assert Phod.Session.send_message("does-not-exist", "hi") == {:error, :not_found}
  end
end
