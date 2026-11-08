defmodule Phod.Tool.Input.LinkPathTest do
  # Sandbox tests for `Phod.Tool.Input.LinkPath`: the final component of a path
  # is not followed, while parent directories still are.
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool.Input
  alias Phod.Tool.Input.LinkPath

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "name, schema type and description" do
    assert LinkPath.name() == :link_path
    assert LinkPath.schema_type() == "string"
    assert is_binary(LinkPath.desc())
  end

  test "keeps a final symlink as the link, not its target", %{root: root} do
    write(root, "target.txt", "t")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, "link.txt"} = LinkPath.validate("link.txt", %{session_root: root})

    assert {:ok, "target.txt"} =
             Phod.Tool.Input.Path.validate("link.txt", %{session_root: root})
  end

  test "keeps a final symlink even when its target is outside the worktree", %{root: root} do
    outside =
      Path.join(Path.dirname(root), "lp-outside-#{System.unique_integer([:positive])}")

    File.write!(outside, "x")
    on_exit(fn -> File.rm(outside) end)
    symlink!(outside, Path.join(root, "out.txt"))

    assert {:ok, "out.txt"} = LinkPath.validate("out.txt", %{session_root: root})
  end

  test "a dangling final symlink is kept", %{root: root} do
    symlink!("missing.txt", Path.join(root, "dangling.txt"))

    assert {:ok, "dangling.txt"} = LinkPath.validate("dangling.txt", %{session_root: root})
  end

  test "still follows a parent symlink that stays inside the worktree", %{root: root} do
    write(root, "work/inside.txt", "ok")
    symlink!("work", Path.join(root, "alias"))

    assert {:ok, "work/inside.txt"} =
             LinkPath.validate("alias/inside.txt", %{session_root: root})
  end

  test "refuses a parent symlink that points outside the worktree", %{root: root} do
    outside =
      Path.join(Path.dirname(root), "lp-outdir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "x.txt"), "x")
    on_exit(fn -> File.rm_rf!(outside) end)
    symlink!(outside, Path.join(root, "escape"))

    assert {:error, "invalid path"} =
             LinkPath.validate("escape/x.txt", %{session_root: root})
  end

  test "refuses a path that is missing", %{root: root} do
    assert {:error, "invalid path"} = LinkPath.validate("nope.txt", %{session_root: root})
  end

  test "refuses a path that ends in . or ..", %{root: root} do
    assert {:error, "invalid path"} = LinkPath.validate(".", %{session_root: root})
    assert {:error, "invalid path"} = LinkPath.validate("lib/..", %{session_root: root})
  end

  test "allow_new_path accepts a name that does not exist yet", %{root: root} do
    assert {:ok, "new.txt"} =
             LinkPath.validate("new.txt", %{session_root: root, allow_new_path: true})
  end

  test "checks its input the same way as Path", %{root: root} do
    assert {:error, "invalid path"} = LinkPath.validate(nil, %{session_root: root})
    assert {:error, "invalid empty path"} = LinkPath.validate("", %{session_root: root})
    assert {:error, "missing session_root"} = LinkPath.validate("a.txt", %{})
    assert {:error, "missing session_root"} = LinkPath.validate("a.txt", nil)
  end

  test "the constructor builds a param of this type" do
    param = Input.link_path(:path, "file", required: true)

    assert param.type == LinkPath
    assert param.required?
  end

  test "refuses .git itself as the final component, and anything under it", %{root: root} do
    write(root, ".git/config", "[core]\n")

    assert {:error, "refusing to access .git"} =
             LinkPath.validate(".git", %{session_root: root})

    assert {:error, "refusing to access .git"} =
             LinkPath.validate(".git/config", %{session_root: root})
  end

  test "refuses a link whose parent is a symlink into .git", %{root: root} do
    write(root, ".git/config", "[core]\n")
    symlink!(".git", Path.join(root, "alias"))

    assert {:error, "refusing to access .git"} =
             LinkPath.validate("alias/config", %{session_root: root})
  end
end
