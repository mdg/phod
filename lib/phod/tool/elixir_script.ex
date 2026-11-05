defmodule Phod.Tool.ElixirScript do
  @moduledoc """
  Runs an LLM-authored Elixir script inside a `bwrap` sandbox: the worktree
  is mounted read-write at its own real path (the script's cwd), the rest
  of the filesystem the real `elixir`/`erl` binaries need is mounted
  read-only, and the sandbox has no network access (`--unshare-net`).

  Unlike every other tool, this one does not go through
  `Phod.Tool.Lib.resolve_path/3` — there is no `path` input to validate.
  Containment is enforced by the OS sandbox instead.

  A non-zero exit status (including an unhandled exception in the script)
  is a normal, successful tool result (`{:ok, %{stdout:, stderr:,
  exit_status:}}`) — the LLM needs to see it to debug its own script.
  `{:error, _}` is reserved for cases where the run could not even be
  attempted: the `elixir`/`erl` toolchain could not be resolved via `asdf
  which`, `bwrap` itself failed to start, or the hard timeout fired.

  Caveat: a `bwrap` setup failure (e.g. a missing bind path) and a script
  that legitimately exits non-zero both surface the same way — a non-zero
  exit status with text on stderr. There is no reliable way to tell them
  apart without parsing bwrap's own error text, which is too fragile to
  rely on, so this is a known blind spot rather than something handled.

  Caveat: `bwrap` auto-creates the parent directories a `--bind`/`--ro-bind`
  target needs as plain writable directories on its own ephemeral sandbox
  root. Since the worktree itself usually lives under a shared top-level
  directory (e.g. `~/phod/tree/...`), a script writing to some *other* path
  under that same top-level directory can appear to succeed — but the write
  lands in that throwaway scaffolding, not the real host filesystem, and
  disappears when the sandbox exits. This isn't a sandbox escape (nothing
  outside the explicit binds is ever reachable), but it means "no error" on
  a write outside the worktree doesn't necessarily mean "wrote somewhere
  real" — only paths inside the worktree persist.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @timeout_ms 10_000
  @max_output_bytes 20_000

  @impl Tool.B
  def name, do: "elixir_script"

  @impl Tool.B
  def description,
    do: """
    Run an Elixir script against the worktree, sandboxed with `bwrap`: the \
    worktree is mounted read-write at its real path (the script's working \
    directory), the rest of the filesystem is read-only, and there is no \
    network access. Only the Elixir/Erlang standard library is available - \
    there is no network access to fetch dependencies, so `Mix.install/2` \
    will not work. The script runs with a hard #{@timeout_ms}ms timeout \
    and output beyond #{@max_output_bytes} bytes per stream is truncated. \
    Use this for anything list_files/read_file/grep/apply_diff can't \
    express: computations, inspecting structured data, quick experiments, \
    or multi-file changes in one shot. Stdout and stderr are returned \
    along with the exit status whether the script exits cleanly or \
    raises - a non-zero exit is not itself a tool error, it's a normal \
    result for you to inspect.\
    """

  @impl Tool.B
  def tool_fields(), do: [:script]

  @impl Tool.B
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "script" => %{
          "type" => "string",
          "description" =>
            "Elixir source to run with `elixir -e`. Runs with the worktree " <>
              "root as its working directory. Standard library only - no " <>
              "network, so Mix.install/2 is unavailable."
        }
      },
      "required" => ["script"]
    }
  end

  @impl Tool.B
  def run(%Tool.Input{script: script, root: root}) do
    with {:ok, toolchain} <- resolve_toolchain() do
      args = bwrap_args(toolchain, root, script)

      case run_sandboxed(args) do
        {:ok, %Rambo{out: out, err: err, status: status}} ->
          {:ok, %{stdout: truncate(out), stderr: truncate(err), exit_status: status}}

        {:error, %Rambo{out: out, err: err, status: status}} ->
          {:ok, %{stdout: truncate(out), stderr: truncate(err), exit_status: status}}

        :timeout ->
          {:error, "script timed out after #{@timeout_ms}ms"}

        {:error, reason} when is_binary(reason) ->
          {:error, "could not run script: #{reason}"}
      end
    end
  end

  # `Rambo.run/3`'s own `:timeout` option schedules a bare `:kill` message
  # via `Process.send_after(self(), :kill, timeout)` that is never
  # cancelled once the command finishes — if it finishes *before* the
  # timeout, that message is left sitting in this process's mailbox. This
  # process goes on to run every other tool call for the rest of the
  # agent's turn (`Phod.Session.Loop` runs them all in one `Task`), so the
  # stray `:kill` gets silently consumed by, and spuriously kills, the
  # *next* unrelated `Rambo.run/3` call this process makes — even a
  # completely different tool with no timeout of its own (confirmed: this
  # crashed `list_files` with an unhandled `{:killed, _}` case clause after
  # a prior `elixir_script` call finished well inside its own timeout).
  # Enforcing the timeout via a disposable `Task` instead avoids this
  # entirely: `Rambo.run/3` is called with no `:timeout` at all, so it
  # never schedules anything, and killing the task on timeout can't leak a
  # message into our mailbox.
  defp run_sandboxed(args) do
    task = Task.async(fn -> Rambo.run("bwrap", args, log: false) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> :timeout
      {:exit, reason} -> {:error, "sandbox process exited: #{inspect(reason)}"}
    end
  end

  # Toolchain resolution -------------------------------------------------------

  # Resolves the *real* elixir/erl binaries via `asdf which`, run normally
  # (outside the sandbox, in this trusted environment) at call time, rather
  # than hardcoding today's asdf version as literal paths - an asdf version
  # bump must not silently break this tool. The asdf shims themselves
  # (`bin/elixir`/`bin/erl`) are thin `/bin/sh` wrappers too fragile to run
  # inside the sandbox (they need `awk`, `/etc/alternatives`, `$HOME`, and a
  # resolvable `.tool-versions` chain), so we bypass them and invoke the
  # real binaries directly.
  defp resolve_toolchain do
    with {:ok, elixir_bin} <- asdf_which("elixir"),
         {:ok, erl_bin} <- asdf_which("erl") do
      elixir_root = elixir_bin |> Path.dirname() |> Path.dirname()
      erlang_root = erl_bin |> Path.dirname() |> Path.dirname()

      # the erts version string (e.g. "erts-17.0.4") varies independently
      # of the erlang/OTP version number, so it must be globbed, not
      # assumed.
      case Path.wildcard(Path.join(erlang_root, "erts-*/bin")) do
        [erts_bin | _] ->
          {:ok,
           %{
             elixir_bin: elixir_bin,
             elixir_root: elixir_root,
             erlang_root: erlang_root,
             erts_bin: erts_bin
           }}

        [] ->
          {:error, "could not find an erts-*/bin directory under #{erlang_root}"}
      end
    end
  end

  defp asdf_which(cmd) do
    case System.cmd("asdf", ["which", cmd], stderr_to_stdout: true) do
      {path, 0} -> {:ok, String.trim(path)}
      {output, _status} -> {:error, "asdf which #{cmd} failed: #{String.trim(output)}"}
    end
  end

  # bwrap invocation ------------------------------------------------------------

  @ro_bind_roots ["/usr", "/lib", "/bin"]
  @optional_ro_bind_roots ["/lib64"]

  defp bwrap_args(toolchain, root, script) do
    ro_binds(toolchain) ++
      [
        "--bind",
        root,
        root,
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--unshare-net",
        "--die-with-parent",
        "--setenv",
        "PATH",
        sandbox_path(toolchain),
        "--unsetenv",
        "HOME",
        "--chdir",
        root,
        "--",
        toolchain.elixir_bin,
        "-e",
        script
      ]
  end

  defp ro_binds(toolchain) do
    system_roots = @ro_bind_roots ++ Enum.filter(@optional_ro_bind_roots, &File.exists?/1)

    Enum.flat_map(system_roots, &["--ro-bind", &1, &1]) ++
      [
        "--ro-bind",
        "/home/mdg/.cargo/bin/",
        "/home/mdg/.cargo/bin/",
        "--ro-bind",
        toolchain.elixir_root,
        toolchain.elixir_root,
        "--ro-bind",
        toolchain.erlang_root,
        toolchain.erlang_root
      ]
  end

  defp sandbox_path(toolchain) do
    [
      "/home/mdg/.cargo/bin/",
      Path.join(toolchain.elixir_root, "bin"),
      Path.join(toolchain.erlang_root, "bin"),
      toolchain.erts_bin,
      "/usr/bin",
      "/bin"
    ]
    |> Enum.join(":")
  end

  # Output handling -------------------------------------------------------------

  # Byte-caps output at @max_output_bytes, then trims back to the nearest
  # valid UTF-8 boundary - a naive byte offset can land mid-codepoint and
  # produce an invalid string.
  defp truncate(output) when byte_size(output) <= @max_output_bytes, do: output

  defp truncate(output) do
    output
    |> binary_part(0, @max_output_bytes)
    |> valid_utf8_prefix()
    |> Kernel.<>("\n... (truncated: output exceeds #{@max_output_bytes} bytes)")
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
