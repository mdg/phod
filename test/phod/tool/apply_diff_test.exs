defmodule Phod.Tool.ApplyDiffTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "applies a single-hunk diff", %{root: root} do
    write(root, "README.md", "hello\nworld\n")

    assert {:ok, %{applied_hunks: 1, created?: false}} =
             Phod.Tool.run(:apply_diff, root, %{
               "path" => "README.md",
               "diff" => "@@ -1,1 +1,2 @@\n hello\n+there\n"
             })

    assert File.read!(Path.join(root, "README.md")) == "hello\nthere\nworld\n"
  end

  test "applies multiple hunks at various offsets", %{root: root} do
    write(root, "nums.txt", "one\ntwo\nthree\nfour\nfive\n")

    {:ok, %{applied_hunks: 2}} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "nums.txt",
        "diff" => "@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n@@ -4,2 +4,2 @@\n four\n-five\n+FIVE\n"
      })

    assert File.read!(Path.join(root, "nums.txt")) == "one\nTWO\nthree\nfour\nFIVE\n"
  end

  test "creates a new file with a /dev/null diff", %{root: root} do
    {:ok, %{created?: true}} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "new/deep/file.txt",
        "diff" => "@@ -0,0 +1,2 @@\n+line one\n+line two"
      })

    assert File.read!(Path.join(root, "new/deep/file.txt")) == "line one\nline two\n"
  end

  test "is atomic: a failing hunk leaves the file untouched", %{root: root} do
    write(root, "README.md", "hello\nworld\n")

    {:error, msg} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "README.md",
        "diff" => "@@ -1,1 +1,1 @@\n-hello\n+HELLO\n@@ -2,1 +2,1 @@\n-bogus line\n+fixed\n"
      })

    assert msg ==
             "hunk #2: context mismatch - could not find expected block near line 2. Re-read the file and try again."

    assert File.read!(Path.join(root, "README.md")) == "hello\nworld\n"
  end

  test "retries search context from a nearby position", %{root: root} do
    write(root, "nums.txt", "one\ntwo\nthree\nfour\nfive\n")

    # header says line 2 but the block is at line 3: still applies
    {:ok, %{applied_hunks: 1}} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "nums.txt",
        "diff" => "@@ -2,2 +2,2 @@\n three\n-four\n+FOUR\n"
      })

    assert File.read!(Path.join(root, "nums.txt")) == "one\ntwo\nthree\nFOUR\nfive\n"
  end

  test "errors when the file does not exist and hunks expect content", %{root: root} do
    {:error, msg} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "missing.md",
        "diff" => "@@ -1,1 +1,1 @@\n-hello\n+HI\n"
      })

    assert msg =~ "hunk #1"
  end

  test "errors on an empty diff", %{root: root} do
    assert {:error, msg} =
             Phod.Tool.run(:apply_diff, root, %{"path" => "README.md", "diff" => "   "})

    assert msg =~ "non-empty unified diff"
  end

  test "errors when no hunks were found", %{root: root} do
    write(root, "README.md", "hello\n")

    {:error, msg} =
      Phod.Tool.run(:apply_diff, root, %{"path" => "README.md", "diff" => "not a diff"})

    assert msg =~ "no unified diff hunks"
  end

  test "rejects escaping worktree paths", %{root: root} do
    {:error, msg} =
      Phod.Tool.run(:apply_diff, root, %{
        "path" => "../evil.md",
        "diff" => "@@ -0,0 +1,1 @@\n+evil\n"
      })

    assert msg =~ "escapes the worktree root"
  end
end
