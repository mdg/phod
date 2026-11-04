defmodule Phod.ToolTest do
  use ExUnit.Case, async: true

  alias Phod.Tool

  test "specs/0 includes an input_schema for every tool" do
    for spec <- Tool.specs() do
      assert %{name: name, description: description, input_schema: schema} = spec
      assert is_atom(name)
      assert is_binary(description)
      assert %{"type" => "object", "properties" => _, "required" => required} = schema
      assert is_list(required)
    end
  end

  test "anthropic_tools/0 builds a well-formed tools array for all 4 tools" do
    tools = Tool.anthropic_tools()
    assert length(tools) == 4

    names = Enum.map(tools, & &1["name"])
    assert Enum.sort(names) == ["apply_diff", "grep", "list_files", "read_file"]

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

  test "fetch_name/1 round-trips all known tool names" do
    for name <- [:list_files, :read_file, :grep, :apply_diff] do
      assert Tool.fetch_name(Atom.to_string(name)) == {:ok, name}
    end
  end

  test "fetch_name/1 returns :error for unknown names" do
    assert Tool.fetch_name("delete_everything") == :error
  end
end
