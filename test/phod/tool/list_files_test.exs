defmodule Phod.Tool.ListFilesTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "lists entries with dir/file types", %{root: root} do
    write(root, "src/index.ex", "x\n")
    write(root, "README.md", "x\n")

    assert {:ok, %{entries: entries}} = Tool.run(:list_files, root, %{})

    assert entries == [
             %{name: "README.md", type: "file"},
             %{name: "src", type: "dir"}
           ]
  end

  test "lists a subdirectory", %{root: root} do
    write(root, "src/index.ex", "x\n")

    assert {:ok, %{path: "src", entries: [%{name: "index.ex", type: "file"}]}} =
             Tool.run(:list_files, root, %{"path" => "src"})
  end

  test "errors on missing paths", %{root: root} do
    assert {:error, msg} = Tool.run(:list_files, root, %{"path" => "nope"})
    assert msg =~ "no such file or directory"
  end
end
