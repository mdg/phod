defmodule Phod.Session.LlmTest do
  use ExUnit.Case, async: true

  alias Phod.Session.Llm

  @messages [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]

  test "parses a successful end_turn response" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "hello back"}],
        "stop_reason" => "end_turn"
      })
    end)

    assert {:ok, %{content: content, stop_reason: "end_turn"}} = Llm.complete(@messages)
    assert [%{"type" => "text", "text" => "hello back"}] = content
  end

  test "parses a successful tool_use response" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{"type" => "tool_use", "id" => "tu_1", "name" => "list_files", "input" => %{}}
        ],
        "stop_reason" => "tool_use"
      })
    end)

    assert {:ok, %{content: content, stop_reason: "tool_use"}} = Llm.complete(@messages)
    assert [%{"type" => "tool_use", "name" => "list_files"}] = content
  end

  test "returns an error on a non-200 status" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"message" => "rate limited"}})
    end)

    assert {:error, reason} = Llm.complete(@messages)
    assert reason =~ "429"
  end

  test "returns an error on a transport failure" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, reason} = Llm.complete(@messages)
    assert is_binary(reason)
  end

  test "short-circuits when the api key is not configured, without a request" do
    original = Application.get_env(:phod, Llm, [])
    Application.put_env(:phod, Llm, Keyword.put(original, :api_key, nil))
    on_exit(fn -> Application.put_env(:phod, Llm, original) end)

    # No stub registered at all: a real request attempt would raise/fail
    # with "no plug/stub" rather than returning our error tuple.
    assert Llm.complete(@messages) == {:error, "LLM_API_KEY is not set"}
  end

  defp capture_system_blocks do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:system_blocks, Jason.decode!(raw)["system"]})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn"
      })
    end)
  end

  test "the static system prompt names no tools" do
    for tool <- ~w(list_files read_files grep patch rm rustc elixir_script) do
      refute Llm.system_prompt() =~ tool
    end
  end

  test "without instructions, the system is only the static prompt" do
    capture_system_blocks()

    assert {:ok, _} = Llm.complete(@messages)
    assert_received {:system_blocks, blocks}
    assert blocks == [%{"type" => "text", "text" => Llm.system_prompt()}]
  end

  test "instructions go in a second block marked for prompt caching" do
    capture_system_blocks()

    assert {:ok, _} = Llm.complete(@messages, "Use snake_case.")
    assert_received {:system_blocks, [static, instructions]}

    assert static == %{"type" => "text", "text" => Llm.system_prompt()}
    assert instructions["text"] =~ "Project instructions (AGENTS.md):"
    assert instructions["text"] =~ "Use snake_case."
    assert instructions["cache_control"] == %{"type" => "ephemeral"}
    refute Map.has_key?(static, "cache_control")
  end

  test "tool_choice: :none disables tool calls but keeps the tools in the request" do
    test_pid = self()

    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(raw)})
      Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}], "stop_reason" => "end_turn"})
    end)

    assert {:ok, _} = Llm.complete(@messages, nil, nil, tool_choice: :none)
    assert_received {:body, body}
    assert body["tool_choice"] == %{"type" => "none"}
    assert is_list(body["tools"]) and body["tools"] != []

    assert {:ok, _} = Llm.complete(@messages)
    assert_received {:body, body}
    refute Map.has_key?(body, "tool_choice")
  end
end
