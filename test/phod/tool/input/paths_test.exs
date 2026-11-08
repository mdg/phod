defmodule Phod.Tool.Input.PathsTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool.Input
  alias Phod.Tool.Input.Paths

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "name, schema type and item type" do
    assert Paths.name() == :paths
    assert Paths.schema_type() == "array"
    assert Paths.item_type() == "string"
    assert is_binary(Paths.desc())
  end

  test "resolves each path inside the session root, in order", %{root: root} do
    write(root, "a.txt", "a")
    write(root, "lib/b.ex", "b")

    assert {:ok, ["a.txt", "lib/b.ex"]} =
             Paths.validate(["a.txt", "lib/b.ex"], %{session_root: root})
  end

  test "drops duplicate paths", %{root: root} do
    write(root, "a.txt", "a")

    assert {:ok, ["a.txt"]} = Paths.validate(["a.txt", "a.txt"], %{session_root: root})
  end

  test "rejects any path that Path would reject", %{root: root} do
    write(root, "a.txt", "a")

    assert {:error, "invalid path"} =
             Paths.validate(["a.txt", "../outside"], %{session_root: root})

    assert {:error, "invalid path"} = Paths.validate(["no-such.txt"], %{session_root: root})

    assert {:error, "invalid empty path"} =
             Paths.validate(["a.txt", ""], %{session_root: root})
  end

  test "rejects an empty list and a non-list", %{root: root} do
    assert {:error, "invalid empty paths"} = Paths.validate([], %{session_root: root})
    assert {:error, "invalid paths"} = Paths.validate("a.txt", %{session_root: root})
  end

  test "requires a session root" do
    assert {:error, "missing session_root"} = Paths.validate(["a.txt"], %{})
  end

  test "the constructor builds a param of this type" do
    param = Input.paths(:paths, "files", required: true)

    assert param.type == Paths
    assert param.required?

    assert Input.to_schema([param])["properties"]["paths"] == %{
             "type" => "array",
             "items" => %{"type" => "string"},
           }
  end

  test "follows a symlink to its target", %{root: root} do
    write(root, "target.txt", "t")
    symlink!("target.txt", Path.join(root, "link.txt"))

    assert {:ok, ["target.txt"]} = Paths.validate(["link.txt"], %{session_root: root})
  end
end
