defmodule PhodWeb.SessionLive.ToolCallTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhodWeb.SessionLive.Components

  # The tool's result carries the patterns it validated.
  defp grep_item(patterns) do
    %{
      id: "tu_1",
      kind: :tool_call,
      name: "grep",
      input: %{"patterns" => patterns},
      result: {:ok, %{"matches" => [], "truncated?" => false, "patterns" => patterns}},
    }
  end

  test "a grep summary shows its first two patterns and ... when there are more" do
    html =
      render_component(&Components.tool_call_block/1,
        item: grep_item(["alpha", "beta", "gamma", "delta"])
      )

    assert html =~ "alpha, beta, ..."
  end

  test "a grep summary with two or fewer patterns shows them all, with no ..." do
    html =
      render_component(&Components.tool_call_block/1, item: grep_item(["alpha", "beta"]))

    assert html =~ "alpha, beta"
    refute html =~ "..."
  end

  test "the expanded grep view lists every pattern" do
    html =
      render_component(&Components.tool_call_block/1,
        item: grep_item(["alpha", "beta", "gamma", "delta"])
      )

    doc = LazyHTML.from_fragment(html)
    listed = doc |> LazyHTML.query("[data-role=tool-call-patterns] code") |> LazyHTML.text()

    assert listed =~ "alpha"
    assert listed =~ "beta"
    assert listed =~ "gamma"
    assert listed =~ "delta"
  end

  test "a grep call whose pattern arrived as a bare string renders without crashing" do
    item = %{
      grep_item([])
      | input: %{"patterns" => "[\"/]nfl/players"},
        result:
          {:ok,
           %{"matches" => [], "truncated?" => false, "patterns" => ["[\"/]nfl/players"]}},
    }

    html = render_component(&Components.tool_call_block/1, item: item)

    assert html =~ "nfl/players"
  end

  test "a grep call with one pattern still lists it in the expanded view" do
    html = render_component(&Components.tool_call_block/1, item: grep_item(["alpha"]))

    assert html =~ "tool-call-patterns"
    assert html =~ "alpha"
  end

  test "a grep call that failed validation shows the error, not its patterns" do
    item = %{grep_item(["[bad"]) | result: {:error, "patterns: invalid regex \"[bad\""}}
    html = render_component(&Components.tool_call_block/1, item: item)

    assert html =~ "patterns: invalid regex"
    refute html =~ "tool-call-patterns"
  end

  test "a pending grep call has no patterns to show yet" do
    item = %{grep_item(["alpha"]) | result: :pending}
    html = render_component(&Components.tool_call_block/1, item: item)

    refute html =~ "tool-call-patterns"
  end

  describe "exec calls" do
    defp exec_item(input, result) do
      %{id: "tu_9", kind: :tool_call, name: "exec", input: input, result: result}
    end

    test "shows the command from the result, not the raw input" do
      item =
        exec_item(%{"cmd" => ["echo", "hi"]}, {:ok, %{"cmd" => ["echo", "hi"], "stdout" => "hi\n", "stderr" => "", "exit_status" => 0}})

      html = render_component(&Components.tool_call_block/1, item: item)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("[data-role=tool-call-cmd]") |> LazyHTML.text() =~ "echo hi"
    end

    test "a malformed raw cmd (a bare string) renders without crashing, showing the error" do
      item = exec_item(%{"cmd" => "ls -l"}, {:error, "cmd: invalid strings"})
      html = render_component(&Components.tool_call_block/1, item: item)

      assert html =~ "cmd: invalid strings"
      refute html =~ "tool-call-cmd"
    end
  end

  describe "peer calls" do
    test "a send names the peer it went to" do
      item = %{
        id: "tu_s",
        kind: :tool_call,
        name: "send",
        input: %{"peer" => "tester/other", "prompt" => "do it", "goal" => "g"},
        result: {:ok, %{"peer" => "tester/other", "status" => "started"}}
      }

      html = render_component(&Components.tool_call_block/1, item: item)
      assert html =~ "send · to tester/other"
    end

    test "a reply says it replies to the sender" do
      item = %{
        id: "tu_r",
        kind: :tool_call,
        name: "reply",
        input: %{"text" => "done", "goal" => "g"},
        result: {:ok, %{"to" => "tester/other", "status" => "started"}}
      }

      html = render_component(&Components.tool_call_block/1, item: item)
      assert html =~ "reply · reply to sender"
    end

    test "a read in a peer's worktree names the peer" do
      item = %{
        id: "tu_g",
        kind: :tool_call,
        name: "grep",
        input: %{"patterns" => ["alpha"], "peer" => "tester/other", "goal" => "g"},
        result: {:ok, %{"matches" => [], "truncated?" => false, "patterns" => ["alpha"]}}
      }

      html = render_component(&Components.tool_call_block/1, item: item)
      assert html =~ "tester/other · alpha"
    end
  end
end
