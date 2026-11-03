defmodule Phod.Tool.LibTest do
  # Sandbox tests for `Phod.Tool.Lib.resolve_path/3` and friends.
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "resolves relative paths within the worktree", %{root: root} do
    write(root, "lib/foo.ex", "1\n")

    assert {:ok, resolved} = Phod.Tool.Lib.resolve_path(root, "lib/foo.ex")
    assert resolved == Path.join(root, "lib/foo.ex")
  end

  test "defaults to the worktree root", %{root: root} do
    assert {:ok, resolved} = Phod.Tool.Lib.resolve_path(root, ".")
    assert resolved == root
  end

  test "rejects absolute paths", %{root: root} do
    assert {:error, msg} = Phod.Tool.Lib.resolve_path(root, "/etc/passwd")
    assert msg =~ "relative to the worktree root"
  end

  test "rejects `..` traversal", %{root: root} do
    assert {:error, msg} = Phod.Tool.Lib.resolve_path(root, "../outside.txt")
    assert msg =~ "escapes the worktree root"
  end

  test "rejects paths in a nonexistent parent", %{root: root} do
    assert {:error, msg} = Phod.Tool.Lib.resolve_path(root, "no/such/dir/file.txt")
    assert msg =~ "invalid worktree path"
  end

  test "accepts new files for creation when allow_new? is set", %{root: root} do
    # strict mode: the parent does not exist yet
    assert {:error, msg} = Phod.Tool.Lib.resolve_path(root, "new/file.txt")
    assert msg =~ "invalid worktree path"

    # allow_new?: apply_diff's mode
    assert {:ok, resolved} = Phod.Tool.Lib.resolve_path(root, "new/file.txt", allow_new?: true)
    assert resolved == Path.join(root, "new/file.txt")
  end

  test "rejects symlinks that escape the worktree", %{root: root} do
    outside = Path.join(Path.dirname(root), "phod-outside-secret.txt")
    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm(outside) end)

    symlink!(outside, Path.join(root, "link.txt"))

    assert {:error, msg} = Phod.Tool.Lib.resolve_path(root, "link.txt")
    assert msg =~ "escapes the worktree root"
  end

  test "allows symlinks that stay inside the worktree", %{root: root} do
    write(root, "work/inside.txt", "ok\n")
    symlink!(Path.join(root, "work/inside.txt"), Path.join(root, "alias.txt"))

    assert {:ok, alias_path} = Phod.Tool.Lib.resolve_path(root, "alias.txt")
    assert alias_path == Path.join(root, "alias.txt")
  end
end
