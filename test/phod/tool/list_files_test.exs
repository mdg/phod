defmodule Phod.Tool.ListFilesTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "lists directory contents as raw `ls -lF` output", %{root: root} do
    write(root, "src/index.ex", "x\n")
    write(root, "README.md", "x\n")

    assert {:ok, %{path: ".", output: output}} = Tool.run("list_files", root, %{})

    assert output =~ ~r/README\.md$/m
    assert output =~ ~r/src\/$/m
  end

  test "lists a subdirectory", %{root: root} do
    write(root, "src/index.ex", "x\n")

    assert {:ok, %{path: "src", output: output}} =
             Tool.run("list_files", root, %{"path" => "src"})

    assert output =~ ~r/index\.ex$/m
  end

  test "errors on missing paths", %{root: root} do
    assert {:error, msg} = Tool.run("list_files", root, %{"path" => "nope"})
    assert msg == "invalid path"
  end
end
