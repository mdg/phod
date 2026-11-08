defmodule Phod.ToolTest do
  use ExUnit.Case, async: true

  alias Phod.Tool

  test "specs/0 includes an input_schema for every tool" do
    for spec <- Tool.specs() do
      assert %{name: name, description: description, input_schema: schema} = spec
      assert is_binary(name)
      assert is_binary(description)
      assert %{"type" => "object", "properties" => _, "required" => required} = schema
      assert is_list(required)
    end
  end

  test "anthropic_tools/0 builds a well-formed tools array for every registered tool" do
    tools = Tool.anthropic_tools()
    assert length(tools) == 8

    names = Enum.map(tools, & &1["name"])

    assert Enum.sort(names) == [
             "exec",
             "grep",
             "list_files",
             "patch",
             "read_files",
             "rm",
             "rustc",
             "write_file",
           ]

    for tool <- tools do
      assert %{"name" => name, "description" => description, "input_schema" => schema} =
               tool

      assert is_binary(name)
      assert is_binary(description)
      assert %{"type" => "object"} = schema
    end
  end

  test "patch's schema does not expose the internal allow_new_path flag" do
    %{"input_schema" => schema} =
      Enum.find(Tool.anthropic_tools(), &(&1["name"] == "patch"))

    refute Map.has_key?(schema["properties"], "allow_new_path")
    assert Enum.sort(Map.keys(schema["properties"])) == ["diff", "goal", "path"]
  end

  test "run/3 returns an error for unknown tool names" do
    assert {:error, msg} = Tool.run("delete_everything", ".", %{})
    assert msg =~ "unknown tool"
  end

  test "no tool schema has a worktree property" do
    for %{"input_schema" => schema} <- Tool.anthropic_tools() do
      refute Map.has_key?(schema["properties"], "worktree")
    end
  end

  test "every tool requires a goal, which is the first thing the model writes for a call" do
    for %{"input_schema" => schema} <- Tool.anthropic_tools() do
      assert "goal" in schema["required"]
      assert schema["properties"]["goal"]["type"] == "string"
    end
  end
end
