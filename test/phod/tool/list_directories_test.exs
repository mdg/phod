defmodule Phod.Tool.ListDirectoriesTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  setup %{root: root} do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)
    write(root, ".gitignore", "build/\n*.log\n")
    write(root, "lib/app/core.ex", "x")
    write(root, "src/x/y/z.ex", "x")
    write(root, "build/out.o", "x")
    write(root, "logs/run.log", "x")
    write(root, "deep/1/2/3/4/f.txt", "x")
    :ok
  end

  test "lists directories, leaving out .git and git-ignored ones", %{root: root} do
    assert {:ok, %{directories: directories}} = Tool.run("list_directories", root, %{})

    assert directories == ["deep", "deep/1", "deep/1/2", "lib", "lib/app", "src", "src/x", "src/x/y"]
    refute Enum.any?(directories, &String.starts_with?(&1, ".git"))
    refute Enum.any?(directories, &String.starts_with?(&1, "build"))
    refute "logs" in directories
  end

  test "max_depth limits how many levels are listed", %{root: root} do
    assert {:ok, %{directories: directories, max_depth: 1}} =
             Tool.run("list_directories", root, %{"max_depth" => 1})

    assert directories == ["deep", "lib", "src"]
  end

  test "the default depth is 3", %{root: root} do
    assert {:ok, %{max_depth: 3, directories: directories}} = Tool.run("list_directories", root, %{})
    refute "deep/1/2/3" in directories
    assert "deep/1/2" in directories
  end

  test "an untracked file that isn't ignored still counts", %{root: root} do
    write(root, "new/thing.ex", "x")

    assert {:ok, %{directories: directories}} = Tool.run("list_directories", root, %{})
    assert "new" in directories
  end

  test "the depth must be within range", %{root: root} do
    assert {:error, "max_depth: must be at most 20, got 21"} =
             Tool.run("list_directories", root, %{"max_depth" => 21})

    assert {:error, "max_depth: must be at least 1, got 0"} =
             Tool.run("list_directories", root, %{"max_depth" => 0})

    assert {:error, "max_depth: invalid integer" <> _} =
             Tool.run("list_directories", root, %{"max_depth" => "3"})
  end

  test "a directory that isn't a git repository is an error", %{root: root} do
    File.rm_rf!(Path.join(root, ".git"))
    File.rm_rf!(Path.join(root, ".gitignore"))
    other = root <> "-not-git"
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)

    assert {:error, "could not list directories: " <> _} =
             Tool.run("list_directories", other, %{})
  end

  test "the tool's schema offers an integer max_depth with a default" do
    %{input_schema: schema} = Enum.find(Tool.specs(), &(&1.name == "list_directories"))
    assert schema["properties"]["max_depth"] == %{"type" => "integer"}
  end
end
