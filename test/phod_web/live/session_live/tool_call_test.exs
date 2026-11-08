defmodule PhodWeb.SessionLive.ToolCallTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhodWeb.SessionLive.Components

  defp grep_item(patterns) do
    %{
      id: "tu_1",
      kind: :tool_call,
      name: "grep",
      input: %{"patterns" => patterns},
      result: {:ok, %{"matches" => [], "truncated?" => false}}
    }
  end

  test "a grep summary shows its first two patterns and ... when there are more" do
    html = render_component(&Components.tool_call_block/1, item: grep_item(["alpha", "beta", "gamma", "delta"]))

    assert html =~ "alpha, beta, ..."
  end

  test "a grep summary with two or fewer patterns shows them all, with no ..." do
    html = render_component(&Components.tool_call_block/1, item: grep_item(["alpha", "beta"]))

    assert html =~ "alpha, beta"
    refute html =~ "..."
  end

  test "the expanded grep view lists the patterns after the first two" do
    html = render_component(&Components.tool_call_block/1, item: grep_item(["alpha", "beta", "gamma", "delta"]))

    doc = LazyHTML.from_fragment(html)
    listed = doc |> LazyHTML.query("[data-role=tool-call-patterns] code") |> LazyHTML.text()

    assert listed =~ "gamma"
    assert listed =~ "delta"
    refute listed =~ "alpha"
  end

  test "no extra list when a grep call has two or fewer patterns" do
    html = render_component(&Components.tool_call_block/1, item: grep_item(["alpha"]))

    refute html =~ "tool-call-patterns"
  end
end
