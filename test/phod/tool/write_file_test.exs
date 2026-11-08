defmodule Phod.Tool.WriteFileTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "creates a new file, with its missing parent directories", %{root: root} do
    assert {:ok, %{path: "lib/new/thing.ex", created?: true, bytes: 6}} =
             Tool.run("write_file", root, %{
               "path" => "lib/new/thing.ex",
               "content" => "hello\n",
             })

    assert File.read!(Path.join(root, "lib/new/thing.ex")) == "hello\n"
  end

  test "replaces the contents of an existing file", %{root: root} do
    write(root, "a.txt", "old\n")

    assert {:ok, %{created?: false, bytes: 4}} =
             Tool.run("write_file", root, %{"path" => "a.txt", "content" => "new\n"})

    assert File.read!(Path.join(root, "a.txt")) == "new\n"
  end

  test "writes through a symlink to its in-worktree target", %{root: root} do
    write(root, "target.txt", "old\n")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, _} =
             Tool.run("write_file", root, %{"path" => "link.txt", "content" => "via link\n"})

    assert File.read!(Path.join(root, "target.txt")) == "via link\n"
  end

  test "rejects empty content and missing content", %{root: root} do
    assert {:error, "content: invalid empty string"} =
             Tool.run("write_file", root, %{"path" => "a.txt", "content" => ""})

    assert {:error, "content is required"} =
             Tool.run("write_file", root, %{"path" => "a.txt"})

    refute File.exists?(Path.join(root, "a.txt"))
  end

  test "rejects a directory path", %{root: root} do
    write(root, "dir/inner.txt", "x")

    assert {:error, msg} =
             Tool.run("write_file", root, %{"path" => "dir", "content" => "x"})

    assert msg == "\"dir\" is a directory, not a file"
  end

  test "cannot write outside the worktree or into .git", %{root: root} do
    assert {:error, "path: invalid path"} =
             Tool.run("write_file", root, %{"path" => "../escape.txt", "content" => "x"})

    assert {:error, "path: refusing to access .git"} =
             Tool.run("write_file", root, %{"path" => ".git/config", "content" => "x"})

    refute File.exists?(Path.join(root, ".git/config"))
  end
end
