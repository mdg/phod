defmodule Phod.Tool.PatchTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  @diff """
  --- a/hello.txt
  +++ b/hello.txt
  @@ -1,2 +1,2 @@
   one
  -two
  +TWO
  """

  test "applies a diff to an existing file, read from stdin", %{root: root} do
    write(root, "hello.txt", "one\ntwo\n")

    assert {:ok, %{path: "hello.txt", output: output}} =
             Tool.run("patch", root, %{"path" => "hello.txt", "diff" => @diff})

    assert output =~ "hello.txt"
    assert File.read!(Path.join(root, "hello.txt")) == "one\nTWO\n"
  end

  test "creates a new file from a diff against /dev/null", %{root: root} do
    diff = """
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1 @@
    +hi
    """

    assert {:ok, _} = Tool.run("patch", root, %{"path" => "new.txt", "diff" => diff})
    assert File.read!(Path.join(root, "new.txt")) == "hi\n"
  end

  test "reports a failed hunk as an error and leaves the file untouched", %{root: root} do
    write(root, "hello.txt", "something else\n")

    assert {:error, msg} =
             Tool.run("patch", root, %{"path" => "hello.txt", "diff" => @diff})

    assert msg =~ "patch failed"
    assert File.read!(Path.join(root, "hello.txt")) == "something else\n"
  end

  test "rejects a path that escapes the worktree", %{root: root} do
    assert {:error, _} =
             Tool.run("patch", root, %{"path" => "../escape.txt", "diff" => @diff})
  end

  describe "diff format" do
    setup %{root: root} do
      write(root, "notes.txt", "one\ntwo\nthree\n")
      :ok
    end

    test "applies a diff wrapped in *** envelope lines", %{root: root} do
      diff =
        "*** Begin Patch\n*** Update File: notes.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n*** End Patch\n"

      assert {:ok, %{path: "notes.txt", applied_hunks: 1}} =
               Tool.run("patch", root, %{"path" => "notes.txt", "diff" => diff})

      assert File.read!(Path.join(root, "notes.txt")) == "one\nTWO\nthree\n"
    end

    test "applies a bare @@ hunk header through the programmatic fallback", %{root: root} do
      diff = "--- a/notes.txt\n+++ b/notes.txt\n@@\n one\n-two\n+TWO\n three\n"

      assert {:ok, %{applied_hunks: 1, method: "programmatic"}} =
               Tool.run("patch", root, %{"path" => "notes.txt", "diff" => diff})

      assert File.read!(Path.join(root, "notes.txt")) == "one\nTWO\nthree\n"
    end

    test "applies a hunk whose line numbers are wrong", %{root: root} do
      diff = "--- a/notes.txt\n+++ b/notes.txt\n@@ -40,3 +40,3 @@\n one\n-two\n+TWO\n three\n"

      assert {:ok, %{applied_hunks: 1}} =
               Tool.run("patch", root, %{"path" => "notes.txt", "diff" => diff})

      assert File.read!(Path.join(root, "notes.txt")) == "one\nTWO\nthree\n"
    end

    test "a diff that fails partway leaves the file untouched", %{root: root} do
      write(root, "notes.txt", "one\ntwo\nthree\n")

      diff = """
      --- a/notes.txt
      +++ b/notes.txt
      @@ -1,3 +1,3 @@
       one
      -two
      +TWO
       three
      @@ -1,1 +1,1 @@
      -missing
      +MISSING
      """

      assert {:error, msg} =
               Tool.run("patch", root, %{"path" => "notes.txt", "diff" => diff})

      assert msg =~ "could not apply the diff"
      assert File.read!(Path.join(root, "notes.txt")) == "one\ntwo\nthree\n"
      refute File.exists?(Path.join(root, "notes.txt.rej"))
    end

    test "the example in the description applies", %{root: root} do
      diff = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"

      assert {:ok, %{applied_hunks: 1}} =
               Tool.run("patch", root, %{"path" => "notes.txt", "diff" => diff})

      assert File.read!(Path.join(root, "notes.txt")) == "one\nTWO\nthree\n"
    end
  end
end
