defmodule Phod.Tool.RmTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "removes the named files", %{root: root} do
    write(root, "a.txt", "a")
    write(root, "lib/b.ex", "b")

    assert {:ok, %{removed: ["a.txt", "lib/b.ex"]}} =
             Tool.run("rm", root, %{"paths" => ["a.txt", "lib/b.ex"]})

    refute File.exists?(Path.join(root, "a.txt"))
    refute File.exists?(Path.join(root, "lib/b.ex"))
    assert File.dir?(Path.join(root, "lib"))
  end

  test "a missing file removes nothing", %{root: root} do
    write(root, "a.txt", "a")

    assert {:error, "paths: invalid path"} = Tool.run("rm", root, %{"paths" => ["a.txt", "gone.txt"]})
    assert File.exists?(Path.join(root, "a.txt"))
  end

  test "refuses a directory, and removes nothing", %{root: root} do
    write(root, "a.txt", "a")
    write(root, "dir/inner.txt", "x")

    assert {:error, "dir is a directory, not a file"} =
             Tool.run("rm", root, %{"paths" => ["a.txt", "dir"]})

    assert File.exists?(Path.join(root, "a.txt"))
    assert File.exists?(Path.join(root, "dir/inner.txt"))
  end

  test "refuses anything under .git", %{root: root} do
    write(root, ".git/config", "x")
    write(root, "a.txt", "a")

    assert {:error, msg} = Tool.run("rm", root, %{"paths" => ["a.txt", ".git/config"]})
    assert msg == "paths: refusing to access .git"
    assert File.exists?(Path.join(root, "a.txt"))
  end

  test "cannot reach outside the worktree", %{root: root} do
    outside = Path.join(Path.dirname(root), "rm-outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    assert {:error, "paths: invalid path"} =
             Tool.run("rm", root, %{"paths" => ["../" <> Path.basename(outside)]})
    assert File.exists?(outside)
  end

  test "removing a symlink removes the link, not its target", %{root: root} do
    write(root, "target.txt", "keep me")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, %{removed: ["link.txt"]}} = Tool.run("rm", root, %{"paths" => ["link.txt"]})
    refute File.exists?(Path.join(root, "link.txt"))
    assert File.read!(Path.join(root, "target.txt")) == "keep me"
  end

  test "cannot remove through a parent symlink that points outside the worktree", %{root: root} do
    outside_dir = Path.join(Path.dirname(root), "rm-outdir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "keep.txt"), "x")
    on_exit(fn -> File.rm_rf!(outside_dir) end)
    symlink!(outside_dir, Path.join(root, "escape"))

    assert {:error, "paths: invalid path"} =
             Tool.run("rm", root, %{"paths" => ["escape/keep.txt"]})

    assert File.exists?(Path.join(outside_dir, "keep.txt"))
  end

  test "requires at least one path", %{root: root} do
    assert {:error, "paths: invalid empty paths"} = Tool.run("rm", root, %{"paths" => []})
  end
end
