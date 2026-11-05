defmodule PhodWeb.SessionLive.FileTreeTest do
  use ExUnit.Case, async: true

  alias PhodWeb.SessionLive.FileTree

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "new/1 expands and lists the worktree root", %{root: root} do
    Phod.Tool.TestHelpers.write(root, "a.txt", "hi")
    Phod.Tool.TestHelpers.write(root, "lib/b.ex", "hi")

    tree = FileTree.new(root)

    assert MapSet.member?(tree.expanded, ".")
    assert {:ok, entries} = tree.entries["."]

    assert [a_entry, lib_entry] = Enum.sort_by(entries, & &1.name)
    assert %{name: "a.txt", type: "file", num_bytes: 2} = a_entry
    assert is_binary(a_entry.mime_type)
    assert %{name: "lib", type: "dir"} = lib_entry
    assert is_binary(lib_entry.mime_type)
  end

  test "toggle/3 expands a collapsed directory, fetching its listing", %{root: root} do
    Phod.Tool.TestHelpers.write(root, "lib/b.ex", "hi")

    tree = FileTree.new(root) |> FileTree.toggle(root, "lib")

    assert MapSet.member?(tree.expanded, "lib")

    assert {:ok, [%{name: "b.ex", type: "file", num_bytes: 2, mime_type: mime}]} =
             tree.entries["lib"]

    assert is_binary(mime)
  end

  test "toggle/3 collapses an already-expanded directory", %{root: root} do
    tree = FileTree.new(root) |> FileTree.toggle(root, ".")

    refute MapSet.member?(tree.expanded, ".")
  end

  test "toggle/3 records an error for a path that doesn't exist", %{root: root} do
    tree = FileTree.new(root) |> FileTree.toggle(root, "nope")

    assert MapSet.member?(tree.expanded, "nope")
    assert {:error, _reason} = tree.entries["nope"]
  end

  test "refresh_expanded/2 re-fetches every expanded directory", %{root: root} do
    tree = FileTree.new(root)
    assert {:ok, []} = tree.entries["."]

    Phod.Tool.TestHelpers.write(root, "new.txt", "hi")
    tree = FileTree.refresh_expanded(tree, root)

    assert {:ok, [%{name: "new.txt", type: "file", num_bytes: 2}]} = tree.entries["."]
  end
end
