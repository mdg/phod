defmodule Phod.Tool.ExecTest do
  use ExUnit.Case, async: true

  alias Phod.Tool

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "runs a command and returns its stdout with a zero exit status", %{root: root} do
    assert {:ok, %{stdout: "hi\n", stderr: "", exit_status: 0}} =
             Tool.run("exec", root, %{"cmd" => ["echo", "hi"]})
  end

  test "a non-zero exit is a normal result, not an error", %{root: root} do
    assert {:ok, %{exit_status: 3}} =
             Tool.run("exec", root, %{"cmd" => ["sh", "-c", "exit 3"]})
  end

  test "stderr is returned separately", %{root: root} do
    assert {:ok, %{stderr: stderr, exit_status: 0}} =
             Tool.run("exec", root, %{"cmd" => ["sh", "-c", "echo oops >&2"]})

    assert stderr == "oops\n"
  end

  test "the working directory is the worktree", %{root: root} do
    assert {:ok, %{stdout: stdout}} = Tool.run("exec", root, %{"cmd" => ["pwd"]})
    assert String.trim(stdout) == root
  end

  test "cannot write inside the worktree by default: it is read-only", %{root: root} do
    assert {:ok, %{exit_status: status}} =
             Tool.run("exec", root, %{"cmd" => ["sh", "-c", "echo made > out.txt"]})

    assert status != 0
    refute File.exists?(Path.join(root, "out.txt"))
  end

  test "with allow_writes: true a command can change files in the worktree", %{root: root} do
    assert {:ok, %{exit_status: 0}} =
             Tool.run("exec", root, %{
               "cmd" => ["sh", "-c", "echo made > out.txt"],
               "allow_writes" => true,
             })

    assert File.read!(Path.join(root, "out.txt")) == "made\n"
  end

  test "allow_writes must be a boolean", %{root: root} do
    assert {:error, msg} =
             Tool.run("exec", root, %{"cmd" => ["echo", "hi"], "allow_writes" => "yes"})

    assert msg =~ "allow_writes: invalid boolean"
  end

  test "a write outside the worktree does not reach the host", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "exec-outside-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(outside) end)

    assert {:ok, _} =
             Tool.run("exec", root, %{"cmd" => ["sh", "-c", "echo x > #{outside}"]})

    refute File.exists?(outside)
  end

  test "system directories are read-only", %{root: root} do
    assert {:ok, %{exit_status: status}} =
             Tool.run("exec", root, %{"cmd" => ["sh", "-c", "echo x > /usr/exec-probe-xyz"]})

    assert status != 0
    refute File.exists?("/usr/exec-probe-xyz")
  end

  test "has no network: only the loopback interface exists", %{root: root} do
    assert {:ok, %{stdout: stdout}} =
             Tool.run("exec", root, %{"cmd" => ["cat", "/proc/net/dev"]})

    interfaces =
      ~r/^\s*([^:\s]+):/m
      |> Regex.scan(stdout, capture: :all_but_first)
      |> List.flatten()

    assert interfaces == ["lo"]
  end

  test "an unknown command is an error", %{root: root} do
    assert {:error, "command not found: no-such-command-xyz"} =
             Tool.run("exec", root, %{"cmd" => ["no-such-command-xyz"]})
  end

  test "requires a non-empty list of strings", %{root: root} do
    assert {:error, "cmd is required"} = Tool.run("exec", root, %{})
    assert {:error, "cmd: invalid empty strings"} = Tool.run("exec", root, %{"cmd" => []})
    assert {:error, "cmd: invalid strings"} = Tool.run("exec", root, %{"cmd" => "ls"})
  end

  test "the tool does not describe its sandbox to the model" do
    %{description: description} = Enum.find(Tool.specs(), &(&1.name == "exec"))
    refute description =~ "bwrap"
    refute description =~ "sandbox"
  end
end
