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

  test "anthropic_tools/0 builds a well-formed tools array for all 6 tools" do
    tools = Tool.anthropic_tools()
    assert length(tools) == 6

    names = Enum.map(tools, & &1["name"])

    assert Enum.sort(names) == [
             "apply_diff",
             "elixir_script",
             "grep",
             "list_files",
             "patch",
             "read_file"
           ]

    for tool <- tools do
      assert %{"name" => name, "description" => description, "input_schema" => schema} = tool
      assert is_binary(name)
      assert is_binary(description)
      assert %{"type" => "object"} = schema
    end
  end

  test "apply_diff's schema does not expose the internal allow_new_path flag" do
    %{"input_schema" => schema} =
      Enum.find(Tool.anthropic_tools(), &(&1["name"] == "apply_diff"))

    refute Map.has_key?(schema["properties"], "allow_new_path")
    assert Enum.sort(Map.keys(schema["properties"])) == ["diff", "path"]
  end

  test "run/3 returns an error for unknown tool names" do
    assert {:error, msg} = Tool.run("delete_everything", ".", %{})
    assert msg =~ "unknown tool"
  end
end
