defmodule Phod.Tool.ElixirScriptTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "captures stdout on a clean exit", %{root: root} do
    assert {:ok, %{stdout: stdout, stderr: _stderr, exit_status: 0}} =
             Tool.run("elixir_script", root, %{"script" => "IO.puts(\"hello\")"})

    assert stdout == "hello\n"
  end

  test "a raised exception is a normal result, not a tool error", %{root: root} do
    script = """
    IO.puts("before")
    raise "boom"
    """

    assert {:ok, %{stdout: stdout, stderr: stderr, exit_status: status}} =
             Tool.run("elixir_script", root, %{"script" => script})

    assert status != 0
    assert stdout == "before\n"
    assert stderr =~ "boom"
  end

  test "cannot write outside the worktree", %{root: root} do
    # Deliberately targets a path under one of the sandbox's own `--ro-bind`
    # mounts (/usr), not just any path outside the worktree. bwrap
    # auto-creates the parent directories a `--bind` target needs as plain
    # writable dirs on its own ephemeral sandbox root, so a sibling path
    # under the *same top-level directory* as the worktree (e.g. another
    # path under /tmp, since `setup_worktree` puts worktrees under
    # System.tmp_dir!/0) would "succeed" into that throwaway scaffolding
    # without ever touching the real host filesystem — not a security
    # issue, but the wrong thing to assert on here. Writing into a real
    # `--ro-bind` target is the actual boundary this test needs to prove.
    outside = "/usr/elixir-script-escape-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm(outside) end)

    script = "File.write!(#{inspect(outside)}, \"escaped\")"

    assert {:ok, %{exit_status: status}} = Tool.run("elixir_script", root, %{"script" => script})

    assert status != 0
    refute File.exists?(outside)
  end

  test "can read and write inside the worktree, visible on the host after the run", %{
    root: root
  } do
    write(root, "input.txt", "hello\n")

    script = """
    content = File.read!("input.txt")
    File.write!("output.txt", String.upcase(content))
    """

    assert {:ok, %{exit_status: 0}} = Tool.run("elixir_script", root, %{"script" => script})
    assert File.read!(Path.join(root, "output.txt")) == "HELLO\n"
  end

  test "has no network access", %{root: root} do
    script = """
    case :gen_tcp.connect(~c"8.8.8.8", 53, [], 2_000) do
      {:ok, _socket} -> IO.puts("connected")
      {:error, reason} -> IO.puts("blocked: \#{inspect(reason)}")
    end
    """

    assert {:ok, %{stdout: stdout, exit_status: 0}} =
             Tool.run("elixir_script", root, %{"script" => script})

    assert stdout =~ "blocked:"
  end

  test "errors on an empty script without starting a subprocess", %{root: root} do
    assert {:error, msg} = Tool.run("elixir_script", root, %{"script" => "   "})
    assert msg == "script: invalid empty string"
  end

  test "a completed run leaves no stray message that could corrupt a later tool call", %{
    root: root
  } do
    # Regression guard: Rambo.run/3's own `:timeout` option schedules a
    # bare `:kill` message via Process.send_after/3 that is never
    # cancelled if the command finishes first - that message would sit in
    # this process's mailbox and be silently consumed by (and spuriously
    # kill) the *next* unrelated Rambo.run/3 call this process makes, even
    # in a different tool with no timeout of its own. `run/1` enforces its
    # timeout via a disposable Task instead specifically to avoid this.
    assert {:ok, %{exit_status: 0}} =
             Tool.run("elixir_script", root, %{"script" => "IO.puts(\"fast\")"})

    assert {:messages, []} = Process.info(self(), :messages)

    # and a subsequent, unrelated Rambo-based tool call runs cleanly too.
    assert {:ok, %{entries: _entries}} = Tool.run("list_files", root, %{})
  end
end
