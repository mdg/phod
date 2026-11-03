defmodule Phod.Tool.GitGrepTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "finds matches with path and line number", %{root: root} do
    write(root, "src/a.ex", "def alpha do\n  1\nend\n")
    write(root, "src/b.ex", "def beta do\n  alpha()\nend\n")

    {:ok, %{matches: matches, truncated?: false}} =
      Tool.run(:git_grep, root, %{"pattern" => "alpha"})

    assert Enum.sort(matches, &(&1.path <= &2.path)) == [
             %{path: "src/a.ex", line_number: 1, line: "def alpha do"},
             %{path: "src/b.ex", line_number: 2, line: "  alpha()"}
           ]
  end

  test "returns no matches for absent patterns", %{root: root} do
    assert {:ok, %{matches: [], truncated?: false}} =
             Tool.run(:git_grep, root, %{"pattern" => "zzz-nowhere"})
  end

  test "accepts a subdirectory path", %{root: root} do
    write(root, "src/a.ex", "alpha\n")
    write(root, "other/a.ex", "alpha\n")

    {:ok, %{matches: matches}} =
      Tool.run(:git_grep, root, %{"pattern" => "alpha", "path" => "src"})

    assert [%{path: "src/a.ex"}] = matches
  end

  test "errors on invalid regex patterns", %{root: root} do
    assert {:error, msg} = Tool.run(:git_grep, root, %{"pattern" => "("})
    assert msg =~ "Unmatched"
  end

  test "errors on empty patterns", %{root: root} do
    assert {:error, msg} = Tool.run(:git_grep, root, %{"pattern" => ""})
    assert msg =~ "invalid empty pattern"
  end
end
