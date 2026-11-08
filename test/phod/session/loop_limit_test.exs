defmodule Phod.Session.LoopLimitTest do
  # Changes the global :max_tool_rounds config, so it can't run alongside the
  # async tests.
  use ExUnit.Case, async: false

  import Phod.Session.TestHelpers, only: [start_and_allow: 2]

  alias Phod.Session.Loop

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  setup do
    previous = Application.get_env(:phod, :max_tool_rounds)
    Application.put_env(:phod, :max_tool_rounds, 1)

    on_exit(fn ->
      Application.put_env(:phod, :max_tool_rounds, previous)
    end)

    :ok
  end

  # Every reply asks for another tool call, so only the round limit can stop a run.
  defp always_uses_a_tool do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "tool_use", "id" => "tu", "name" => "list_files", "input" => %{}}],
        "stop_reason" => "tool_use"
      })
    end)
  end

  test "a run stops after the configured number of tool rounds", %{root: root} do
    always_uses_a_tool()
    message = %{"role" => "user", "content" => [%{"type" => "text", "text" => "go"}]}

    assert {:error, "tool loop exceeded max rounds (1)", _messages} =
             Loop.run([message], root, fn _ -> :ok end)
  end

  test "a session records a run error in its log", %{user: user, tree: tree, root: root} do
    always_uses_a_tool()
    start_and_allow(user, tree)
    id = Phod.Session.session_id(user, tree)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    assert :ok = Phod.Session.send_message(id, "go")

    assert_receive {:session_snapshot,
                    %{status: :idle, last_error: "tool loop exceeded max rounds (1)"}},
                   2_000

    log = File.read!(Phod.Session.Log.path(root))
    assert log =~ "**run error:**"
    assert log =~ "tool loop exceeded max rounds (1)"
  end
end
