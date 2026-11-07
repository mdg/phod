defmodule Phod.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  defp unique_tree, do: "wt-#{System.unique_integer([:positive])}"

  defp text_response(text, stop_reason \\ "end_turn") do
    fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop_reason
      })
    end
  end

  import Phod.Session.TestHelpers, only: [start_and_allow: 2]

  test "send_message/2 runs the loop and settles back to :idle", %{id: id, user: user, tree: tree} do
    Req.Test.expect(Phod.Session.LlmStub, text_response("hello!"))

    pid = start_and_allow(user, tree)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "hi")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :running}}, 1000
    assert_receive {:session_snapshot, %{status: :idle, messages: messages}}, 1000
    assert length(messages) == 2
  end

  test "a second send_message/2 while running is rejected with :busy", %{id: id, user: user, tree: tree} do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      send(test_pid, :llm_called)
      receive do: (:release -> :ok)
      Req.Test.json(conn, %{"content" => [], "stop_reason" => "end_turn"})
    end)

    pid = start_and_allow(user, tree)

    assert :ok = Phod.Session.send_message(id, "first")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)
    assert_receive :llm_called, 1000

    assert {:error, :busy} = Phod.Session.send_message(id, "second")

    # release the gated stub so the test doesn't leave a hanging process
    for task_child <- Task.Supervisor.children(Phod.Session.TaskSupervisor) do
      send(task_child, :release)
    end
  end

  test "patch round-trips through the GenServer and is visible in get_snapshot/1", %{id: id, root: root, user: user, tree: tree} do
    diff = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n"

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "patch",
            "input" => %{"path" => "new.txt", "diff" => diff}
          }
        ],
        "stop_reason" => "tool_use"
      })
    end)

    Req.Test.expect(Phod.Session.LlmStub, text_response("done"))

    pid = start_and_allow(user, tree)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "create new.txt")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :idle, edits: [_ | _]}}, 1000

    snapshot = Phod.Session.get_snapshot(id)
    assert [%{path: "new.txt", created?: true}] = snapshot.edits
    assert File.read!(Path.join(root, "new.txt")) == "hello\n"
  end

  test "a crashing agent run logs the crash reason and settles back to :idle", %{id: id, user: user, tree: tree} do
    Req.Test.stub(Phod.Session.LlmStub, fn _conn -> raise "boom" end)

    pid = start_and_allow(user, tree)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    log =
      capture_log(fn ->
        assert :ok = Phod.Session.send_message(id, "hi")
        Req.Test.allow(Phod.Session.LlmStub, self(), pid)

        assert_receive {:session_snapshot, %{status: :idle, last_error: last_error}}, 1000
        assert last_error =~ "agent run crashed"
      end)

    assert log =~ "agent run crashed for session #{id}"
    assert log =~ "boom"
  end

  test "the session log records the user, tool calls, tool results and replies", %{id: id, root: root, user: user, tree: tree} do
    log_path = Phod.Session.Log.path(root)
    on_exit(fn -> File.rm(log_path) end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{"type" => "tool_use", "id" => "tu_1", "name" => "list_files", "input" => %{}}
        ],
        "stop_reason" => "tool_use"
      })
    end)

    Req.Test.expect(Phod.Session.LlmStub, text_response("all listed"))

    pid = start_and_allow(user, tree)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "what files are here?", "Ada")
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :idle}}, 1000

    log = File.read!(log_path)

    # the system prompt is at the top, from when the session started
    assert log =~ "# Session log"
    assert log =~ "**system prompt:**"

    assert log =~ "### Ada ·"
    assert log =~ "what files are here?"
    assert log =~ "**tool call:** `list_files`"
    assert log =~ "**tool result:**"
    assert log =~ "all listed"
    assert log =~ "### phod ·"
  end

  test "ensure_started/3 called twice returns the same pid", %{user: user, tree: tree} do
    assert {:ok, pid} = Phod.Session.ensure_started(user, tree)
    assert {:ok, ^pid} = Phod.Session.ensure_started(user, tree)
  end

  describe "ensure_started/3 worktree format" do
    setup do
      base = Application.fetch_env!(:phod, :worktree_base)
      on_exit(fn -> File.rm_rf!(Path.join(base, "octocat")) end)
      :ok
    end

    test "starts a session on an existing <worktree_base>/<user>/<tree> directory" do
      tree = unique_tree()
      root = Phod.Session.worktree_root("octocat", tree)
      File.mkdir_p!(root)

      assert {:ok, pid} = Phod.Session.ensure_started("octocat", tree)
      assert %{id: "octocat/" <> ^tree, worktree_root: ^root} = :sys.get_state(pid)
    end

    test "rejects a worktree directory that does not exist" do
      tree = unique_tree()
      root = Phod.Session.worktree_root("octocat", tree)

      assert {:error, {:invalid_worktree_root, ^root}} =
               Phod.Session.ensure_started("octocat", tree)

      assert Phod.Session.whereis("octocat/" <> tree) == :error
    end

    test "rejects a tree that is nested, hidden, or escapes the base" do
      nested = "a/b-#{System.unique_integer([:positive])}"
      File.mkdir_p!(Phod.Session.worktree_root("octocat", nested))

      assert {:error, {:invalid_worktree_root, _}} =
               Phod.Session.ensure_started("octocat", nested)

      assert {:error, {:invalid_worktree_root, _}} =
               Phod.Session.ensure_started("octocat", "../../outside")
    end

    test "rejects a user that fails the GitHub naming rule" do
      tree = unique_tree()
      File.mkdir_p!(Phod.Session.worktree_root("-bad-user", tree))
      on_exit(fn -> File.rm_rf!(Phod.Session.worktree_root("-bad-user", tree)) end)

      assert {:error, {:invalid_worktree_root, _}} =
               Phod.Session.ensure_started("-bad-user", tree)
    end
  end

  test "get_snapshot/1 and send_message/2 report :not_found for an unknown id" do
    assert Phod.Session.get_snapshot("does-not-exist") == {:error, :not_found}
    assert Phod.Session.send_message("does-not-exist", "hi") == {:error, :not_found}
  end
end
