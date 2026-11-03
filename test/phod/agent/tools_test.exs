defmodule Phod.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias Phod.Agent.Tools

  setup do
    root =
      Path.join([System.tmp_dir!(), "phod-tools-test-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  describe "sandbox (Phod.Agent.Tool.resolve/2)" do
    test "resolves relative paths within the worktree", %{root: root} do
      write(root, "lib/foo.ex", "1\n")

      assert {:ok, resolved} = Phod.Agent.Tool.resolve(root, "lib/foo.ex")
      assert resolved == Path.join(root, "lib/foo.ex")
    end

    test "defaults to the worktree root", %{root: root} do
      assert {:ok, resolved} = Phod.Agent.Tool.resolve(root, ".")
      assert resolved == root
    end

    test "rejects absolute paths", %{root: root} do
      assert {:error, msg} = Phod.Agent.Tool.resolve(root, "/etc/passwd")
      assert msg =~ "relative to the worktree root"
    end

    test "rejects `..` traversal", %{root: root} do
      assert {:error, msg} = Phod.Agent.Tool.resolve(root, "../outside.txt")
      assert msg =~ "escapes the worktree root"
    end

    test "accepts new files for creation when the X-ancestor exists", %{root: root} do
      # strict mode: the parent does not exist yet
      assert {:error, msg} = Phod.Agent.Tool.resolve(root, "new/file.txt")
      assert msg =~ "invalid worktree path"

      # allow_new?: apply_diff's mode
      assert {:ok, resolved} = Phod.Agent.Tool.resolve(root, "new/file.txt", allow_new?: true)
      assert resolved == Path.join(root, "new/file.txt")
    end

    test "rejects symlinks that escape the worktree", %{root: root} do
      outside = Path.join(Path.dirname(root), "phod-outside-secret.txt")
      File.write!(outside, "secret\n")
      on_exit(fn -> File.rm(outside) end)

      symlink!(outside, Path.join(root, "link.txt"))

      assert {:error, msg} = Phod.Agent.Tool.resolve(root, "link.txt")
      assert msg =~ "escapes the worktree root"
    end

    test "allows symlinks that stay inside the worktree", %{root: root} do
      write(root, "work/inside.txt", "ok\n")
      symlink!(Path.join(root, "work/inside.txt"), Path.join(root, "alias.txt"))

      assert {:ok, alias_path} = Phod.Agent.Tool.resolve(root, "alias.txt")
      assert alias_path == Path.join(root, "alias.txt")
    end

    defp symlink!(target, link) do
      assert :ok = :file.make_symlink(String.to_charlist(target), String.to_charlist(link))
    end
  end

  describe "list_files" do
    test "lists entries with dir/file types", %{root: root} do
      write(root, "src/index.ex", "x\n")
      write(root, "README.md", "x\n")

      assert {:ok, %{entries: entries}} = Tools.run("list_files", root, %{})

      assert entries == [
               %{name: "README.md", type: "file"},
               %{name: "src", type: "dir"}
             ]
    end

    test "lists a subdirectory", %{root: root} do
      write(root, "src/index.ex", "x\n")

      assert {:ok, %{path: "src", entries: [%{name: "index.ex", type: "file"}]}} =
               Tools.run("list_files", root, %{"path" => "src"})
    end

    test "errors on missing paths", %{root: root} do
      assert {:error, msg} = Tools.run("list_files", root, %{"path" => "nope"})
      assert msg =~ "no such file or directory"
    end
  end

  describe "read_file" do
    test "returns numbered content", %{root: root} do
      write(root, "README.md", "hello\nworld\n")

      assert {:ok, %{path: "README.md", content: content}} =
               Tools.run("read_file", root, %{"path" => "README.md"})

      assert content == "1: hello\n2: world"
    end

    test "errors on missing files", %{root: root} do
      assert {:error, msg} = Tools.run("read_file", root, %{"path" => "nope.txt"})
      assert msg =~ "no such file or directory"
    end

    test "errors on directories with a helpful hint", %{root: root} do
      write(root, "src/index.ex", "x\n")

      assert {:error, msg} = Tools.run("read_file", root, %{"path" => "src"})
      assert msg =~ "use list_files"
    end
  end

  describe "git_grep" do
    test "finds matches with path and line number", %{root: root} do
      write(root, "src/a.ex", "def alpha do\n  1\nend\n")
      write(root, "src/b.ex", "def beta do\n  alpha()\nend\n")

      {:ok, %{matches: matches, truncated?: false}} =
        Tools.run("git_grep", root, %{"pattern" => "alpha"})

      assert Enum.sort(matches, &(&1.path <= &2.path)) == [
               %{path: "src/a.ex", line_number: 1, line: "def alpha do"},
               %{path: "src/b.ex", line_number: 2, line: "  alpha()"}
             ]
    end

    test "returns no matches for absent patterns", %{root: root} do
      assert {:ok, %{matches: [], truncated?: false}} =
               Tools.run("git_grep", root, %{"pattern" => "zzz-nowhere"})
    end

    test "accepts a subdirectory path", %{root: root} do
      write(root, "src/a.ex", "alpha\n")
      write(root, "other/a.ex", "alpha\n")

      {:ok, %{matches: matches}} =
        Tools.run("git_grep", root, %{"pattern" => "alpha", "path" => "src"})

      assert [%{path: "src/a.ex"}] = matches
    end

    test "errors on invalid regex patterns", %{root: root} do
      assert {:error, msg} = Tools.run("git_grep", root, %{"pattern" => "("})
      assert msg =~ "Unmatched"
    end

    test "errors on empty patterns", %{root: root} do
      assert {:error, msg} = Tools.run("git_grep", root, %{"pattern" => ""})
      assert msg =~ "non-empty string"
    end
  end

  describe "apply_diff" do
    test "applies a single-hunk diff", %{root: root} do
      write(root, "README.md", "hello\nworld\n")

      assert {:ok, %{applied_hunks: 1, created?: false}} =
               Tools.run("apply_diff", root, %{
                 "path" => "README.md",
                 "diff" => "@@ -1,1 +1,2 @@\n hello\n+there\n"
               })

      assert File.read!(Path.join(root, "README.md")) == "hello\nthere\nworld\n"
    end

    test "applies multiple hunks at various offsets", %{root: root} do
      write(root, "nums.txt", "one\ntwo\nthree\nfour\nfive\n")

      {:ok, %{applied_hunks: 2}} =
        Tools.run("apply_diff", root, %{
          "path" => "nums.txt",
          "diff" => "@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n@@ -4,2 +4,2 @@\n four\n-five\n+FIVE\n"
        })

      assert File.read!(Path.join(root, "nums.txt")) == "one\nTWO\nthree\nfour\nFIVE\n"
    end

    test "creates a new file with a /dev/null diff", %{root: root} do
      {:ok, %{created?: true}} =
        Tools.run("apply_diff", root, %{
          "path" => "new/deep/file.txt",
          "diff" => "@@ -0,0 +1,2 @@\n+line one\n+line two"
        })

      assert File.read!(Path.join(root, "new/deep/file.txt")) == "line one\nline two\n"
    end

    test "is atomic: a failing hunk leaves the file untouched", %{root: root} do
      write(root, "README.md", "hello\nworld\n")

      {:error, msg} =
        Tools.run("apply_diff", root, %{
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
        Tools.run("apply_diff", root, %{
          "path" => "nums.txt",
          "diff" => "@@ -2,2 +2,2 @@\n three\n-four\n+FOUR\n"
        })

      assert File.read!(Path.join(root, "nums.txt")) == "one\ntwo\nthree\nFOUR\nfive\n"
    end

    test "errors when the file does not exist and hunks expect content", %{root: root} do
      {:error, msg} =
        Tools.run("apply_diff", root, %{
          "path" => "missing.md",
          "diff" => "@@ -1,1 +1,1 @@\n-hello\n+HI\n"
        })

      assert msg =~ "hunk #1"
    end

    test "errors on an empty diff", %{root: root} do
      assert {:error, msg} =
               Tools.run("apply_diff", root, %{"path" => "README.md", "diff" => "   "})

      assert msg =~ "non-empty unified diff"
    end

    test "errors when no hunks were found", %{root: root} do
      {:error, msg} =
        Tools.run("apply_diff", root, %{"path" => "README.md", "diff" => "not a diff"})

      assert msg =~ "no unified diff hunks"
    end

    test "rejects escaping worktree paths", %{root: root} do
      {:error, msg} =
        Tools.run("apply_diff", root, %{
          "path" => "../evil.md",
          "diff" => "@@ -0,0 +1,1 @@\n+evil\n"
        })

      assert msg =~ "escapes the worktree root"
    end
  end
end
