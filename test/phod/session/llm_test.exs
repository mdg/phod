defmodule Phod.Session.LlmTest do
  use ExUnit.Case, async: true

  alias Phod.Session.Llm

  @messages [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]

  test "parses a successful end_turn response" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "hello back"}],
        "stop_reason" => "end_turn",
      })
    end)

    assert {:ok, %{content: content, stop_reason: "end_turn"}} = Llm.complete(@messages)
    assert [%{"type" => "text", "text" => "hello back"}] = content
  end

  test "parses a successful tool_use response" do
    Req.Test.stub(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{"type" => "tool_use", "id" => "tu_1", "name" => "list_files", "input" => %{}},
        ],
        "stop_reason" => "tool_use",
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
end
