defmodule Phod.Tool.ReadFileTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "returns numbered content", %{root: root} do
    write(root, "README.md", "hello\nworld\n")

    assert {:ok, %{path: "README.md", content: content}} =
             Tool.run("read_file", root, %{"path" => "README.md"})

    assert content == "1: hello\n2: world"
  end

  test "errors on missing files", %{root: root} do
    assert {:error, msg} = Tool.run("read_file", root, %{"path" => "nope.txt"})
    assert msg == "path: invalid path"
  end

  test "errors on directories with a helpful hint", %{root: root} do
    write(root, "src/index.ex", "x\n")

    assert {:error, msg} = Tool.run("read_file", root, %{"path" => "src"})
    assert msg == "\"src\" is a directory, use list_files"
  end
end
