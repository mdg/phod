defmodule Phod.Tool.ListFilesTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  describe "parse_line/1" do
    test "parses a regular file" do
      assert Tool.ListFiles.parse_line("-rw-rw-r-- 1 mdg mdg 123 Nov  4 22:16 foo.ex") ==
               %{name: "foo.ex", type: "file", num_bytes: 123}
    end

    test "parses a directory, stripping the trailing /" do
      assert Tool.ListFiles.parse_line("drwxrwxr-x 2 mdg mdg 4096 Nov  4 22:16 lib/") ==
               %{name: "lib", type: "dir", num_bytes: 4096}
    end

    test "parses an executable file, stripping the * indicator" do
      assert Tool.ListFiles.parse_line("-rwxrwxr-x 1 mdg mdg 10 Nov  4 22:16 run.sh*") ==
               %{name: "run.sh", type: "file", num_bytes: 10}
    end

    test "parses a symlink by its own name, not its target" do
      assert Tool.ListFiles.parse_line("lrwxrwxrwx 1 mdg mdg 5 Nov  4 22:16 link -> target.txt") ==
               %{name: "link", type: "symlink", num_bytes: 5}
    end

    test "parses a symlink pointing at a directory, ignoring the target's trailing /" do
      assert Tool.ListFiles.parse_line("lrwxrwxrwx 1 mdg mdg 3 Nov  4 22:16 to_dir -> sub/") ==
               %{name: "to_dir", type: "symlink", num_bytes: 3}
    end

    test "returns nil for the `total N` header line" do
      assert Tool.ListFiles.parse_line("total 4") == nil
    end

    test "returns nil for an unparseable line" do
      assert Tool.ListFiles.parse_line("not a listing line at all") == nil
    end
  end

  describe "parse_ls/1" do
    test "parses entries and filters out ., .., and .git" do
      ls_output = """
      total 24
      drwxrwxr-x 3 mdg mdg 4096 Nov  4 22:42 .
      drwxrwxr-x 3 mdg mdg 4096 Nov  2 18:56 ..
      -rw-rw-r-- 1 mdg mdg   59 Nov  2 18:56 .git
      -rw-rw-r-- 1 mdg mdg  337 Nov  4 19:42 main.rs
      -rw-rw-r-- 1 mdg mdg    6 Nov  2 19:34 README.md
      drwxrwxr-x 2 mdg mdg 4096 Nov  4 22:19 sub
      lrwxrwxrwx 1 mdg mdg   12 Nov  4 22:19 taco.txt -> sub/taco.txt
      """

      assert Tool.ListFiles.parse_ls(ls_output) == [
               %{name: "main.rs", type: "file", num_bytes: 337},
               %{name: "README.md", type: "file", num_bytes: 6},
               %{name: "sub", type: "dir", num_bytes: 4096},
               %{name: "taco.txt", type: "symlink", num_bytes: 12}
             ]
    end
  end

  describe "attach_mime_types/2" do
    test "adds a mime_type and charset to each entry, resolving names against dir_abs", %{
      root: root
    } do
      write(root, "README.md", "hello\n")

      entries = [%{name: "README.md", type: "file", num_bytes: 6}]

      assert [%{name: "README.md", mime_type: mime_type, charset: charset}] =
               Tool.ListFiles.attach_mime_types(entries, root)

      assert mime_type == "text/plain"
      assert charset == "us-ascii"
    end

    test "returns an empty list for an empty entry list" do
      assert Tool.ListFiles.attach_mime_types([], "/unused") == []
    end
  end

  describe "parse_mime_info/1" do
    test "extracts the mime type and charset" do
      assert Tool.ListFiles.parse_mime_info("text/plain; charset=us-ascii") ==
               %{mime_type: "text/plain", charset: "us-ascii"}
    end

    test "trims the leading padding `file -i` uses to align columns" do
      assert Tool.ListFiles.parse_mime_info("   inode/x-empty; charset=binary") ==
               %{mime_type: "inode/x-empty", charset: "binary"}
    end

    test "handles inode pseudo-types for directories and symlinks" do
      assert Tool.ListFiles.parse_mime_info("inode/directory; charset=binary") ==
               %{mime_type: "inode/directory", charset: "binary"}

      assert Tool.ListFiles.parse_mime_info("inode/symlink; charset=binary") ==
               %{mime_type: "inode/symlink", charset: "binary"}
    end

    test "charset is nil when there's no charset segment" do
      assert Tool.ListFiles.parse_mime_info("text/plain") ==
               %{mime_type: "text/plain", charset: nil}
    end

    test "finds the charset segment even when there are extra segments" do
      assert Tool.ListFiles.parse_mime_info("text/plain; charset=us-ascii; foo=bar") ==
               %{mime_type: "text/plain", charset: "us-ascii"}
    end
  end

  test "lists directory contents as structured entries", %{root: root} do
    write(root, "src/index.ex", "x\n")
    write(root, "README.md", "x\n")

    assert {:ok, %{path: ".", entries: entries}} = Tool.run("list_files", root, %{})

    assert [readme, src] = Enum.sort_by(entries, & &1.name)
    assert %{name: "README.md", type: "file", num_bytes: 2} = readme
    assert readme.mime_type == "text/plain"
    assert readme.charset == "us-ascii"
    assert %{name: "src", type: "dir"} = src
    assert src.mime_type == "inode/directory"
    assert src.charset == "binary"
  end

  test "lists a subdirectory", %{root: root} do
    write(root, "src/index.ex", "x\n")

    assert {:ok, %{path: "src", entries: [%{name: "index.ex", type: "file", num_bytes: 2}]}} =
             Tool.run("list_files", root, %{"path" => "src"})
  end

  test "errors on missing paths", %{root: root} do
    assert {:error, msg} = Tool.run("list_files", root, %{"path" => "nope"})
    assert msg == "invalid path"
  end

  describe "all parameter" do
    test "defaults to false, hiding dotfiles", %{root: root} do
      write(root, ".env", "secret\n")
      write(root, "README.md", "x\n")

      assert {:ok, %{entries: entries}} = Tool.run("list_files", root, %{})

      assert Enum.map(entries, & &1.name) == ["README.md"]
    end

    test "passes -A to ls and surfaces dotfiles when true", %{root: root} do
      write(root, ".env", "secret\n")
      write(root, "README.md", "x\n")

      assert {:ok, %{entries: entries}} = Tool.run("list_files", root, %{"all" => true})

      assert Enum.map(entries, & &1.name) |> Enum.sort() == [".env", "README.md"]
    end

    test "still filters out .git, ., and .. even when all is true", %{root: root} do
      write(root, ".git", "not a real git dir, just a file\n")
      write(root, "README.md", "x\n")

      assert {:ok, %{entries: entries}} = Tool.run("list_files", root, %{"all" => true})

      assert Enum.map(entries, & &1.name) == ["README.md"]
    end

    test "errors when all is not a boolean", %{root: root} do
      assert {:error, msg} = Tool.run("list_files", root, %{"all" => "true"})
      assert msg == ~S[invalid boolean, got: "true"]
    end
  end
end
