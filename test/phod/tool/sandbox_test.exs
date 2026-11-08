defmodule Phod.Tool.SandboxTest do
  use ExUnit.Case, async: true

  import Phod.Tool.TestHelpers

  alias Phod.Tool.Sandbox

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  defp sh(root, script, opts \\ []) do
    Sandbox.run(["/bin/sh", "-c", script],
      [root: root, cwd: root, timeout_ms: 10_000] ++ opts
    )
  end

  test "the root is read-only by default", %{root: root} do
    assert {:ok, %{exit_status: status}} = sh(root, "echo x > new.txt")
    assert status != 0
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "with allow_writes: true the root is writable", %{root: root} do
    assert {:ok, %{exit_status: 0}} = sh(root, "echo x > new.txt", allow_writes: true)
    assert File.read!(Path.join(root, "new.txt")) == "x\n"
  end

  test "a .git file (as in a git worktree) is hidden: it reads as empty", %{root: root} do
    write(root, ".git", "gitdir: /some/where/else\n")

    assert {:ok, %{stdout: "", exit_status: 0}} = sh(root, "cat .git")
    assert {:ok, %{stdout: "", exit_status: 0}} = sh(root, "cat .git", allow_writes: true)
  end

  test "a .git file cannot be changed, even with allow_writes", %{root: root} do
    write(root, ".git", "gitdir: /x\n")

    assert {:ok, %{exit_status: status}} = sh(root, "echo hacked > .git", allow_writes: true)
    assert status != 0
    assert File.read!(Path.join(root, ".git")) == "gitdir: /x\n"
  end

  test "a .git directory is hidden: it appears empty", %{root: root} do
    write(root, ".git/config", "[core]\n")

    assert {:ok, %{stdout: "", exit_status: 0}} =
             sh(root, "ls -A .git", allow_writes: true)

    assert {:ok, %{exit_status: status}} = sh(root, "cat .git/config", allow_writes: true)
    assert status != 0
  end

  test "the repo's .git stays hidden from the sandbox when the root is writable", %{root: root} do
    write(root, ".git/HEAD", "ref: refs/heads/main\n")

    assert {:ok, %{stdout: stdout}} = sh(root, "cat .git/HEAD 2>/dev/null; echo done", allow_writes: true)
    assert stdout == "done\n"
  end

  test "a write outside the root fails, rather than appearing to succeed", %{root: root} do
    probe = Path.join(System.tmp_dir!(), "sandbox-probe-#{System.unique_integer([:positive])}")

    assert {:ok, %{exit_status: status, stderr: stderr}} =
             sh(root, "echo x > #{probe}", allow_writes: true)

    assert status != 0
    assert stderr =~ "Read-only file system"
    refute File.exists?(probe)
  end
end
