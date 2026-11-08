defmodule Phod.Session.LoopTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Session.Loop

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  defp text_response(text, stop_reason \\ "end_turn") do
    fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop_reason,
      })
    end
  end

  defp tool_use_response(id, name, input) do
    fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
        "stop_reason" => "tool_use",
      })
    end
  end

  defp user_message(text) do
    %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
  end

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

  test "a plain end_turn round returns immediately" do
    Req.Test.expect(Phod.Session.LlmStub, text_response("hi there"))

    {on_event, events} = collect_events()
    messages = [user_message("hello")]

    assert {:ok, result} = Loop.run(messages, "/unused", on_event)
    assert length(result) == 2
    assert [{:message_appended, %{"role" => "assistant"}}] = events.()
  end

  test "runs a list_files tool round then finishes", %{root: root} do
    write(root, "a.ex", "x\n")

    Req.Test.expect(Phod.Session.LlmStub, tool_use_response("tu_1", "list_files", %{}))
    Req.Test.expect(Phod.Session.LlmStub, text_response("done"))

    {on_event, events} = collect_events()
    messages = [user_message("list files")]

    assert {:ok, result} = Loop.run(messages, root, on_event)
    assert length(result) == 4

    assert [
             {:message_appended, %{"role" => "assistant"}},
             {:message_appended, %{"role" => "user", "content" => [tool_result]}},
             {:message_appended, %{"role" => "assistant"}},
           ] = events.()

    assert %{"type" => "tool_result", "tool_use_id" => "tu_1"} = tool_result
    refute Map.has_key?(tool_result, "is_error")
    assert %{"entries" => entries} = Jason.decode!(tool_result["content"])
    assert [%{"name" => "a.ex"}] = entries
  end

  test "a successful patch records an edit and writes the file", %{root: root} do
    # patch does not create missing parent directories, unlike apply_diff did
    File.mkdir_p!(Path.join(root, "new"))
    diff = "--- /dev/null\n+++ b/new/file.txt\n@@ -0,0 +1,2 @@\n+line one\n+line two\n"

    Req.Test.expect(
      Phod.Session.LlmStub,
      tool_use_response("tu_1", "patch", %{"path" => "new/file.txt", "diff" => diff})
    )

    Req.Test.expect(Phod.Session.LlmStub, text_response("done"))

    {on_event, events} = collect_events()
    messages = [user_message("create the file")]

    assert {:ok, _result} = Loop.run(messages, root, on_event)
    assert File.read!(Path.join(root, "new/file.txt")) == "line one\nline two\n"

    assert Enum.any?(events.(), fn
             {:edit_recorded, %{path: "new/file.txt", created?: true}} -> true
             _ -> false
           end)
  end

  test "a tool error is reported but does not abort the loop", %{root: root} do
    Req.Test.expect(
      Phod.Session.LlmStub,
      tool_use_response("tu_1", "read_file", %{"path" => "missing.txt"})
    )

    Req.Test.expect(Phod.Session.LlmStub, text_response("ok, it's missing"))

    {on_event, events} = collect_events()
    messages = [user_message("read missing.txt")]

    assert {:ok, _result} = Loop.run(messages, root, on_event)

    [_assistant, %{"content" => [tool_result]}, _final] =
      events.() |> Enum.map(&elem(&1, 1))

    assert tool_result["is_error"] == true
  end

  test "an unknown tool name is handled safely", %{root: root} do
    Req.Test.expect(
      Phod.Session.LlmStub,
      tool_use_response("tu_1", "delete_everything", %{})
    )

    Req.Test.expect(Phod.Session.LlmStub, text_response("can't do that"))

    {on_event, events} = collect_events()
    messages = [user_message("delete everything")]

    assert {:ok, _result} = Loop.run(messages, root, on_event)

    [_assistant, %{"content" => [tool_result]}, _final] =
      events.() |> Enum.map(&elem(&1, 1))

    assert tool_result["is_error"] == true
    assert tool_result["content"] =~ "unknown tool"
  end

  test "the max-rounds safety valve trips when the model never stops", %{root: root} do
    Req.Test.stub(Phod.Session.LlmStub, tool_use_response("tu_1", "list_files", %{}))

    {on_event, _events} = collect_events()
    messages = [user_message("loop forever")]

    assert {:error, reason, messages_so_far} = Loop.run(messages, root, on_event, 3)
    assert reason =~ "max rounds (3)"
    assert length(messages_so_far) > length(messages)
  end

  test "an LLM error mid-loop preserves the messages accumulated so far", %{root: root} do
    Req.Test.expect(Phod.Session.LlmStub, tool_use_response("tu_1", "list_files", %{}))

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    {on_event, _events} = collect_events()
    messages = [user_message("list then fail")]

    assert {:error, reason, messages_so_far} = Loop.run(messages, root, on_event)
    assert is_binary(reason)
    # original user message + assistant tool_use + user tool_result
    assert length(messages_so_far) == 3
  end
end
