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
    assert length(tools) == 6

    names = Enum.map(tools, & &1["name"])
    assert Enum.sort(names) == ["grep", "list_files", "patch", "read_files", "rm", "rustc"]

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
    assert Enum.sort(Map.keys(schema["properties"])) == ["diff", "path"]
  end

  test "run/3 returns an error for unknown tool names" do
    assert {:error, msg} = Tool.run("delete_everything", ".", %{})
    assert msg =~ "unknown tool"
  end

  describe "worktree selection" do
    import Phod.Tool.TestHelpers

    setup {Phod.Tool.TestHelpers, :setup_worktree}

    setup %{root: root} do
      second = Path.join(Path.dirname(root), "second-#{System.unique_integer([:positive])}")
      File.mkdir_p!(second)
      write(root, "first.txt", "from first\n")
      write(second, "second.txt", "from second\n")
      on_exit(fn -> File.rm_rf!(second) end)

      %{worktrees: [{"u/first", root}, {"u/second", second}], second: second}
    end

    test "a single worktree adds no worktree property to the schema" do
      for %{"input_schema" => schema} <- Tool.anthropic_tools(["u/only"]) do
        refute Map.has_key?(schema["properties"], "worktree")
      end
    end

    test "several worktrees add an enum of their names to every tool", %{
      worktrees: worktrees
    } do
      names = Enum.map(worktrees, &elem(&1, 0))

      for %{"input_schema" => schema} <- Tool.anthropic_tools(names) do
        assert schema["properties"]["worktree"]["enum"] == names
        refute "worktree" in Map.get(schema, "required", [])
      end
    end

    test "defaults to the first worktree when none is named", %{worktrees: worktrees} do
      assert {:ok, %{files: [%{content: "1: from first"}]}} =
               Tool.run("read_files", worktrees, %{"paths" => ["first.txt"]})
    end

    test "acts on the named worktree", %{worktrees: worktrees} do
      assert {:ok, %{files: [%{content: "1: from second"}]}} =
               Tool.run("read_files", worktrees, %{
                 "paths" => ["second.txt"],
                 "worktree" => "u/second"
               })
    end

    test "a file that is only in another worktree is not found by default", %{
      worktrees: worktrees
    } do
      assert {:error, "paths: invalid path"} =
               Tool.run("read_files", worktrees, %{"paths" => ["second.txt"]})
    end

    test "an unknown worktree name is an error", %{worktrees: worktrees} do
      assert {:error, msg} =
               Tool.run("read_files", worktrees, %{
                 "paths" => ["first.txt"],
                 "worktree" => "u/nope"
               })

      assert msg =~ ~S(unknown worktree "u/nope")
    end

    test "with one worktree, a worktree name is ignored", %{worktrees: [first | _]} do
      assert {:ok, _} =
               Tool.run("read_files", [first], %{
                 "paths" => ["first.txt"],
                 "worktree" => "x"
               })
    end
  end
end
