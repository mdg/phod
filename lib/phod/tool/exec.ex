defmodule Phod.Tool.Exec do
  @moduledoc """
  Runs one command in the worktree with no network access. `cmd` is the program
  and its arguments as separate strings. The program is found on the host's
  `PATH` (or given as a path relative to the worktree root). A non-zero exit is
  a normal result. Runs through `Phod.Tool.Sandbox`.
  """

  alias Phod.Tool
  alias Phod.Tool.Sandbox

  @behaviour Tool.B

  @timeout_ms 30_000

  @impl Tool.B
  def name, do: "exec"

  @impl Tool.B
  def description,
    do: """
    Run a command in the worktree, with the worktree as its working directory. \
    `cmd` is the program and its arguments as separate strings, for example \
    ["ls", "-l", "lib"]. There is no network access, so anything that downloads \
    dependencies will fail. The worktree is read-only unless `allow_writes` is \
    true, in which case commands can change files in it. Returns stdout, stderr, \
    and the exit status; a non-zero \
    exit is a normal result to read, not an error. The command is stopped after \
    #{div(@timeout_ms, 1000)} seconds.\
    """

  @impl Tool.B
  def params do
    [
      Tool.Input.strings(:cmd, "The program and its arguments, one string each.", required: true),
      Tool.Input.bool(:allow_writes, "Let the command change files in the worktree.",
        default: false
      )
    ]
  end

  @impl Tool.B
  def run(%{cmd: [program | args], allow_writes: allow_writes}, %{session_root: root}) do
    case find_program(program, root) do
      {:ok, exe} ->
        Sandbox.run([exe | args],
          root: root,
          allow_writes: allow_writes,
          ro: [Path.dirname(exe)],
          path: [Path.dirname(exe)],
          cwd: root,
          timeout_ms: @timeout_ms
        )

      :error ->
        {:error, "command not found: #{program}"}
    end
  end

  # A program with a slash is a path, relative to the worktree; a bare name is
  # looked up on the host's PATH.
  defp find_program(program, root) do
    if String.contains?(program, "/") do
      exe = Path.expand(program, root)
      if File.regular?(exe), do: {:ok, exe}, else: :error
    else
      case System.find_executable(program) do
        nil -> :error
        exe -> {:ok, exe}
      end
    end
  end
end
