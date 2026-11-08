defmodule Phod.Tool.Sandbox do
  @moduledoc """
  Runs a command in a `bwrap` sandbox. Internal to the tools; the LLM is never
  told about it.

    * Only the system directories, the worktree root, and the hidden `.git`
      are visible. The rest of the host's filesystem doesn't exist in the
      sandbox.
    * The whole filesystem is read-only except the bound directories, so a
      write outside them fails rather than appearing to succeed.
    * The worktree root is read-only unless `allow_writes: true`.
    * The worktree's `.git` is hidden either way: a `.git` file (as in a git
      worktree) is replaced by an empty file, and a `.git` directory by an
      empty one.
    * No network, and the environment is cleared.

  Output is byte-capped per stream. The command runs in a `Task` with a hard
  timeout, so a timeout can't leave a stray message in the caller's mailbox:
  `Rambo.run/3`'s own timeout schedules a `:kill` message that isn't cancelled
  when the command finishes first.
  """

  @system_ro ["/usr", "/lib", "/bin", "/lib64"]
  @system_path ["/usr/bin", "/bin"]
  @max_output_bytes 20_000

  @doc """
  Runs `argv` (a program path and its arguments) and returns its output:

    * `:root` (required): the worktree root, bound in the sandbox
    * `:allow_writes`: whether the root is writable (default `false`)
    * `:ro`: further directories it may read (system directories are always readable)
    * `:path`: extra directories on the command's `PATH`
    * `:cwd` (required): the working directory
    * `:timeout_ms` (required): the hard time limit

  A non-zero exit is `{:ok, %{exit_status: n, ...}}`. `{:error, reason}` means
  the command could not be run, or it timed out.
  """
  @spec run([String.t()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def run([_program | _] = argv, opts) do
    timeout = Keyword.fetch!(opts, :timeout_ms)
    args = bwrap_args(argv, opts)
    task = Task.async(fn -> Rambo.run("bwrap", args, log: false) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %Rambo{} = result}} -> {:ok, output(result)}
      {:ok, {:error, %Rambo{} = result}} -> {:ok, output(result)}
      {:ok, {:error, reason}} when is_binary(reason) -> {:error, "could not run command: #{reason}"}
      {:ok, {:error, _reason}} -> {:error, "could not run command"}
      nil -> {:error, "timed out after #{timeout}ms"}
      {:exit, _reason} -> {:error, "could not run command"}
    end
  end

  # The full `bwrap` argument list, built from named steps. The order matters:
  #
  #   1. system directories, read-only
  #   2. `/proc` and `/dev` (bwrap creates their mount points, so they come
  #      before the root is made read-only)
  #   3. the worktree root, read-only or writable
  #   4. the hidden `.git`, mounted over the root
  #   5. `--remount-ro /`, which makes the sandbox's own root read-only. It comes
  #      after every mount, and it isn't recursive, so the bound directories
  #      keep their own modes.
  #   6. no network, cleared environment, and the working directory
  #   7. `--`, then the command itself
  defp bwrap_args(argv, opts) do
    root = Keyword.fetch!(opts, :root)
    cwd = Keyword.fetch!(opts, :cwd)
    allow_writes? = Keyword.get(opts, :allow_writes, false)
    extra_ro = Keyword.get(opts, :ro, [])
    extra_path = Keyword.get(opts, :path, [])

    Enum.concat([
      system_mounts(extra_ro),
      kernel_mounts(),
      root_mount(root, allow_writes?),
      hide_git(root),
      read_only_root(),
      isolation(extra_path),
      ["--chdir", cwd, "--"],
      argv
    ])
  end

  defp system_mounts(extra_ro) do
    dirs = Enum.filter(@system_ro, &File.dir?/1) ++ extra_ro
    Enum.flat_map(dirs, &["--ro-bind", &1, &1])
  end

  defp kernel_mounts, do: ["--proc", "/proc", "--dev", "/dev"]

  defp root_mount(root, true), do: ["--bind", root, root]
  defp root_mount(root, false), do: ["--ro-bind", root, root]

  # A `.git` file (git worktrees) becomes an empty read-only file. It's bound
  # from an empty regular file, not /dev/null: bwrap mounts bind sources nodev,
  # so a device node can't be read. A `.git` directory becomes an empty tmpfs.
  defp hide_git(root) do
    git = Path.join(root, ".git")

    cond do
      File.dir?(git) -> ["--tmpfs", git]
      File.exists?(git) -> ["--ro-bind", empty_file(), git]
      true -> []
    end
  end

  defp empty_file do
    path = Path.join(System.tmp_dir!(), "phod-sandbox-empty")
    unless File.exists?(path), do: File.write!(path, "")
    path
  end

  defp read_only_root, do: ["--remount-ro", "/"]

  defp isolation(extra_path) do
    path = Enum.join(@system_path ++ extra_path, ":")

    [
      "--unshare-net",
      "--die-with-parent",
      "--clearenv",
      "--setenv",
      "PATH",
      path
    ]
  end

  defp output(%Rambo{out: out, err: err, status: status}) do
    %{stdout: truncate(out), stderr: truncate(err), exit_status: status}
  end

  # Byte-caps at @max_output_bytes, then trims back to a valid UTF-8 boundary.
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
