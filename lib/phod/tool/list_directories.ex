defmodule Phod.Tool.ListDirectories do
  @moduledoc """
  Lists the directories in the worktree, down to `max_depth` levels. Files that
  git ignores, and everything under `.git`, are left out: the list comes from
  `git ls-files`, which applies `.gitignore` and the other exclude files.

  Directories that hold no tracked or unignored files don't appear, since git
  doesn't track empty directories.
  """

  alias Phod.Tool
  alias Phod.Tool.Input

  @behaviour Tool.B

  @default_depth 3
  @max_depth 20
  @max_directories 1_000

  @impl Tool.B
  def name, do: "list_directories"

  @impl Tool.B
  def description,
    do: """
    List the directories in the worktree, down to max_depth levels deep \
    (default #{@default_depth}; a directory at the top level has depth 1). Files \
    and directories that git ignores are left out, and so is .git. Paths are \
    relative to the worktree root. Use this to see the project's layout before \
    listing files in it.\
    """

  @impl Tool.B
  def params do
    [
      Input.integer(:max_depth, "How many directory levels to list.",
        default: @default_depth,
        min: 1,
        max: @max_depth
      )
    ]
  end

  @impl Tool.B
  def run(%{max_depth: max_depth}, %{session_root: root}) do
    case tracked_and_unignored_files(root) do
      {:ok, files} ->
        directories = files |> Enum.flat_map(&parent_directories(&1, max_depth)) |> Enum.uniq() |> Enum.sort()

        {:ok,
         %{
           max_depth: max_depth,
           directories: Enum.take(directories, @max_directories),
           truncated?: length(directories) > @max_directories
         }}

      {:error, reason} ->
        {:error, "could not list directories: #{reason}"}
    end
  end

  # `-z` keeps paths with unusual characters intact. Ignored files are left
  # out by --exclude-standard; .git never appears in ls-files.
  defp tracked_and_unignored_files(root) do
    case Rambo.run("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
           cd: root,
           log: false
         ) do
      {:ok, %Rambo{out: out}} ->
        {:ok, out |> String.split(<<0>>, trim: true)}

      {:error, %Rambo{err: err}} ->
        {:error, String.trim(err)}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  # The directories above a file, from the top down, no deeper than max_depth.
  defp parent_directories(file, max_depth) do
    segments = Path.split(file)
    directories = Enum.drop(segments, -1)

    for depth <- 1..min(length(directories), max_depth)//1 do
      directories |> Enum.take(depth) |> Path.join()
    end
  end
end
