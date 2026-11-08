defmodule Phod.Tool.ReadFilesTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "returns numbered content for one file", %{root: root} do
    write(root, "README.md", "hello\nworld\n")

    assert {:ok, %{files: [%{path: "README.md", content: "1: hello\n2: world"}]}} =
             Tool.run("read_files", root, %{"paths" => ["README.md"]})
  end

  test "reads several files in one call, in the order given", %{root: root} do
    write(root, "a.txt", "alpha\n")
    write(root, "lib/b.ex", "beta\n")

    assert {:ok,
            %{
              files: [
                %{path: "lib/b.ex", content: "1: beta"},
                %{path: "a.txt", content: "1: alpha"},
              ],
            }} =
             Tool.run("read_files", root, %{"paths" => ["lib/b.ex", "a.txt"]})
  end

  test "a file that can't be read is an entry error; the others are still returned", %{
    root: root,
  } do
    write(root, "src/index.ex", "x\n")
    write(root, "ok.txt", "fine\n")

    assert {:ok,
            %{files: [%{path: "src", error: error}, %{path: "ok.txt", content: "1: fine"}]}} =
             Tool.run("read_files", root, %{"paths" => ["src", "ok.txt"]})

    assert error == "\"src\" is a directory, use list_files"
  end

  test "a path that does not resolve fails the whole call before any file is read", %{
    root: root,
  } do
    write(root, "ok.txt", "fine\n")

    assert {:error, "paths: invalid path"} =
             Tool.run("read_files", root, %{"paths" => ["ok.txt", "nope.txt"]})
  end

  test "a file that is a symlink is read through to its target", %{root: root} do
    write(root, "target.txt", "linked\n")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, %{files: [%{path: "target.txt", content: "1: linked"}]}} =
             Tool.run("read_files", root, %{"paths" => ["link.txt"]})
  end

  test "requires a list of paths", %{root: root} do
    assert {:error, "paths: invalid paths"} =
             Tool.run("read_files", root, %{"paths" => "a.txt"})
  end
end
