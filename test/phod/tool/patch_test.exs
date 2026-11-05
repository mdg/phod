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

    assert {:error, msg} = Tool.run("patch", root, %{"path" => "hello.txt", "diff" => @diff})
    assert msg =~ "patch failed"
    assert File.read!(Path.join(root, "hello.txt")) == "something else\n"
  end

  test "rejects a path that escapes the worktree", %{root: root} do
    assert {:error, _} = Tool.run("patch", root, %{"path" => "../escape.txt", "diff" => @diff})
  end
end
