defmodule Phod.Session.NetworkLoopTest do
  use ExUnit.Case, async: true

  alias Phod.Session.{Loop, Network}

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  @network_config %{
    http: %{"docs" => %{base_url: "http://docs.internal:8080"}},
    postgres: %{
      "analytics" => %{
        host: "localhost",
        port: 5433,
        database: "phod_test",
        user: "phodapi",
        password: "phod123"
      }
    }
  }

  setup do
    {:ok, network} = Network.normalize(@network_config)
    %{network: network}
  end

  defp user_message(text), do: %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}

  defp respond(conn, content, stop_reason) do
    Req.Test.json(conn, %{"content" => content, "stop_reason" => stop_reason})
  end

  defp tool_names(tools), do: Enum.map(tools, & &1["name"])

  test "a user run is offered one tool per connection", %{root: root, network: network} do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:tools, Jason.decode!(raw)["tools"]})
      respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn")
    end)

    assert {:ok, _} = Loop.run([user_message("hi")], root, fn _ -> :ok end, network: network)
    assert_received {:tools, tools}
    assert "http_docs" in tool_names(tools)
    assert "postgres_analytics" in tool_names(tools)
  end

  test "a peer run is not offered any network tool", %{root: root, network: network} do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:tools, Jason.decode!(raw)["tools"]})
      respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn")
    end)

    assert {:ok, _} =
             Loop.run([user_message("hi")], root, fn _ -> :ok end, mode: :peer, network: network)

    assert_received {:tools, tools}
    refute Enum.any?(tool_names(tools), &String.starts_with?(&1, "http_"))
    refute Enum.any?(tool_names(tools), &String.starts_with?(&1, "postgres_"))
  end

  test "a user run can call its http connection, and gets the response", %{root: root, network: network} do
    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond(conn, [%{"type" => "tool_use", "id" => "tu_1", "name" => "http_docs",
                       "input" => %{"path" => "/guide", "goal" => "read the guide"}}], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond(conn, [%{"type" => "text", "text" => "done"}], "end_turn") end)

    Req.Test.stub(Phod.Tool.HttpStub, fn conn -> Req.Test.text(conn, "the guide") end)

    {on_event, events} = collect_events()
    assert {:ok, _} = Loop.run([user_message("read it")], root, on_event, network: network)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["content"] =~ "the guide"
    refute result["is_error"]
  end

  test "a read-only postgres connection refuses a write through the loop", %{root: root, network: network} do
    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond(conn, [%{"type" => "tool_use", "id" => "tu_1", "name" => "postgres_analytics",
                       "input" => %{"sql" => "CREATE TEMP TABLE x (a int)", "goal" => "make a table"}}], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn") end)

    {on_event, events} = collect_events()
    assert {:ok, _} = Loop.run([user_message("write")], root, on_event, network: network)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["is_error"] == true
    assert result["content"] =~ "read-only"
  end

  test "a network tool in a peer run is an unknown tool", %{root: root, network: network} do
    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      respond(conn, [%{"type" => "tool_use", "id" => "tu_1", "name" => "http_docs",
                       "input" => %{"path" => "/", "goal" => "try"}}], "tool_use")
    end)

    Req.Test.expect(Phod.Session.LlmStub, fn conn -> respond(conn, [%{"type" => "text", "text" => "ok"}], "end_turn") end)

    {on_event, events} = collect_events()
    assert {:ok, _} = Loop.run([user_message("hi")], root, on_event, mode: :peer, network: network)

    [_assistant, %{"content" => [result]} | _] = events.() |> Enum.map(&elem(&1, 1))
    assert result["is_error"] == true
    assert result["content"] =~ "unknown tool"
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
end
