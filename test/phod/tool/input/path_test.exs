defmodule Phod.Tool.Input.PathTest do
  # Sandbox tests for `Phod.Tool.Input.Path.resolve/3` and `validate/2`.
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool.Input.Path, as: PathInput

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "name and schema type" do
    assert PathInput.name() == :path
    assert PathInput.schema_type() == "string"
    assert is_binary(PathInput.desc())
  end

  test "validate/2 resolves a path within the session root", %{root: root} do
    write(root, "lib/foo.ex", "1\n")

    assert {:ok, "lib/foo.ex"} = PathInput.validate("lib/foo.ex", %{session_root: root})
  end

  test "validate/2 rejects a non-string or empty path", %{root: root} do
    opts = %{session_root: root}

    assert {:error, "invalid path"} = PathInput.validate(nil, opts)
    assert {:error, "invalid empty path"} = PathInput.validate("", opts)
  end

  test "validate/2 requires a session root" do
    assert {:error, "missing session_root"} = PathInput.validate("lib/foo.ex", %{})
  end

  test "resolves relative paths within the worktree", %{root: root} do
    write(root, "lib/foo.ex", "1\n")

    assert {:ok, "lib/foo.ex"} = PathInput.resolve(root, "lib/foo.ex", false)
  end

  test "defaults to the worktree root", %{root: root} do
    assert {:ok, "."} = PathInput.resolve(root, ".", false)
  end

  test "rejects absolute paths", %{root: root} do
    assert {:error, "invalid path"} = PathInput.resolve(root, "/etc/passwd", false)
  end

  test "rejects `..` traversal", %{root: root} do
    assert {:error, "invalid path"} = PathInput.resolve(root, "../outside.txt", false)
  end

  test "rejects paths in a nonexistent parent", %{root: root} do
    assert {:error, "invalid path"} = PathInput.resolve(root, "no/such/dir/file.txt", false)
  end

  test "accepts new files for creation when allow_new_path is set", %{root: root} do
    # strict mode: the parent does not exist yet
    assert {:error, "invalid path"} = PathInput.resolve(root, "new/file.txt", false)

    # allow_new_path: patch's mode
    assert {:ok, "new/file.txt"} = PathInput.resolve(root, "new/file.txt", true)
  end

  test "rejects symlinks that escape the worktree", %{root: root} do
    outside = Path.join(Path.dirname(root), "phod-outside-secret.txt")
    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm(outside) end)

    symlink!(outside, Path.join(root, "link.txt"))

    assert {:error, "invalid path"} = PathInput.resolve(root, "link.txt", false)
  end

  test "rejects absolute symlinks to inside the worktree", %{root: root} do
    write(root, "work/inside.txt", "ok\n")
    symlink!(Path.join(root, "work/inside.txt"), Path.join(root, "alias.txt"))

    assert {:error, "invalid path"} = PathInput.resolve(root, "alias.txt", false)
  end

  test "allows symlinks that stay inside the worktree", %{root: root} do
    write(root, "work/inside.txt", "ok\n")
    symlink!("work/inside.txt", Path.join(root, "alias.txt"))

    assert {:ok, "work/inside.txt"} = PathInput.resolve(root, "alias.txt", false)
  end

  test "follows a final symlink to its target", %{root: root} do
    write(root, "target.txt", "t")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, "target.txt"} = PathInput.validate("link.txt", %{session_root: root})
  end
end
