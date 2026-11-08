defmodule Phod.Tool.Sandbox do
  @moduledoc """
  Runs a command in a `bwrap` sandbox: no network, the environment cleared, and
  the whole filesystem read-only except the bound directories. A write outside
  them fails. The worktree root is read-only unless
  `allow_writes: true`. Either way, its `.git` is hidden: a `.git` file (as in a
  git worktree) is replaced by an empty file, and a `.git` directory by an
  empty one. Only the system directories and the root are visible; the rest of
  the host's filesystem doesn't exist in the sandbox. Internal to the tools;
  the LLM is never told about it.

  Output is byte-capped per stream. The command runs in a `Task` with a hard
  timeout, so a timeout can't leave a stray message in the caller's mailbox
  (see `Phod.Tool.ElixirScript` for why `Rambo`'s own timeout is avoided).
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
    task = Task.async(fn -> Rambo.run(bwrap(), args, log: false) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %Rambo{} = result}} -> {:ok, output(result)}
      {:ok, {:error, %Rambo{} = result}} -> {:ok, output(result)}
      {:ok, {:error, reason}} when is_binary(reason) -> {:error, "could not run command: #{reason}"}
      {:ok, {:error, _reason}} -> {:error, "could not run command"}
      nil -> {:error, "timed out after #{timeout}ms"}
      {:exit, _reason} -> {:error, "could not run command"}
    end
  end

  defp bwrap, do: "bwrap"

  defp bwrap_args(argv, opts) do
    root = Keyword.fetch!(opts, :root)
    cwd = Keyword.fetch!(opts, :cwd)
    root_bind = if Keyword.get(opts, :allow_writes, false), do: "--bind", else: "--ro-bind"
    ro = Enum.filter(@system_ro, &File.dir?/1) ++ Keyword.get(opts, :ro, [])
    path = Enum.join(@system_path ++ Keyword.get(opts, :path, []), ":")

    # The sandbox's own root is writable by default, and writes to it vanish
    # when the command exits, which looks like success. `--remount-ro /` makes
    # it read-only, so those writes fail instead. It comes after every mount
    # (mount points are created as they're bound), and it's not recursive, so
    # the bound directories keep their own modes.
    Enum.flat_map(ro, &["--ro-bind", &1, &1]) ++
      ["--proc", "/proc", "--dev", "/dev"] ++
      [root_bind, root, root] ++
      hide_git(root) ++
      ["--remount-ro", "/"] ++
      [
        "--unshare-net",
        "--die-with-parent",
        "--clearenv",
        "--setenv",
        "PATH",
        path,
        "--chdir",
        cwd,
        "--"
      ] ++ argv
  end

  # Mounted after the root, so it covers the root's own `.git`. A `.git` file
  # (git worktrees) becomes an empty read-only file; a `.git` directory becomes
  # an empty tmpfs. The file is bound from an empty regular file, not
  # /dev/null: bwrap mounts bind sources nodev, so a device node can't be read.
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
