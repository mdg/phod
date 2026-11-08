defmodule Phod.Tool.Input.LinkPathsTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool.Input
  alias Phod.Tool.Input.LinkPaths

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "name, schema type and item type" do
    assert LinkPaths.name() == :link_paths
    assert LinkPaths.schema_type() == "array"
    assert LinkPaths.item_type() == "string"
    assert is_binary(LinkPaths.desc())
  end

  test "keeps each final symlink as the link", %{root: root} do
    write(root, "target.txt", "t")
    symlink!("target.txt", Path.join(root, "link.txt"))
    write(root, "plain.txt", "p")

    assert {:ok, ["link.txt", "plain.txt"]} =
             LinkPaths.validate(["link.txt", "plain.txt"], %{session_root: root})
  end

  test "drops duplicates and keeps order", %{root: root} do
    write(root, "a.txt", "a")
    write(root, "b.txt", "b")

    assert {:ok, ["b.txt", "a.txt"]} =
             LinkPaths.validate(["b.txt", "a.txt", "b.txt"], %{session_root: root})
  end

  test "rejects an entry that LinkPath would reject", %{root: root} do
    write(root, "a.txt", "a")

    assert {:error, "invalid path"} =
             LinkPaths.validate(["a.txt", "../outside"], %{session_root: root})

    assert {:error, "invalid path"} =
             LinkPaths.validate(["gone.txt"], %{session_root: root})
  end

  test "rejects an empty list and a non-list", %{root: root} do
    assert {:error, "invalid empty paths"} = LinkPaths.validate([], %{session_root: root})
    assert {:error, "invalid paths"} = LinkPaths.validate("a.txt", %{session_root: root})
  end

  test "the constructor builds a param of this type" do
    param = Input.link_paths(:paths, "files", required: true)

    assert param.type == LinkPaths
    assert param.required?

    assert Input.to_schema([param])["properties"]["paths"] == %{
             "type" => "array",
             "items" => %{"type" => "string"},
           }
  end
end
