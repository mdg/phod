defmodule Phod.Tool.Input.LinkPath do
  @moduledoc """
  The LinkPath input type: a path whose final component is not followed.

  A symlink in the final component stays a link, so an operation on the path
  acts on the link itself (removing it, for example) and never on what it
  points to. Symlinks in the parent directories are still followed, and must
  still resolve inside the worktree, as with `Phod.Tool.Input.Path`.
  """

  import Rexult

  alias Phod.Tool.Input
  alias Phod.Tool.Input.Path, as: PathInput

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :link_path

  @impl Input.Type
  def desc() do
    """
    A path parameter pointing to a file or symlink in the repo, not followed
    """
  end

  @impl Input.Type
  def schema_type() do
    "string"
  end

  @doc """
  Validate that the path is valid and contained within the root, without
  following a symlink in its final component. Options as for
  `Phod.Tool.Input.Path.validate/2`.
  """
  @impl Input.Type
  def validate(path, opts) do
    case PathInput.check_input(path, opts) do
      :ok -> resolve(opts.session_root, path, Map.get(opts, :allow_new_path, false))
      {:error, _msg} = error -> error
    end
  end

  @doc """
  Resolves `path` like `Phod.Tool.Input.Path.resolve/3`, except that the final
  component is kept as written. The result names the link itself when the
  final component is a symlink. A path ending in `.` or `..` is refused, since
  it doesn't name a single entry.
  """
  @spec resolve(String.t(), term(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(root, path, allow_new?) do
    dir = Path.dirname(path)
    base = Path.basename(path)

    if base in ["", ".", ".."] do
      {:error, "invalid path"}
    else
      PathInput.resolve(root, dir, allow_new?)
      |> ok_and_then(fn safe_dir ->
        link = if safe_dir == ".", do: base, else: Path.join(safe_dir, base)

        if allow_new? or match?({:ok, _stat}, File.lstat(Path.join(root, link))) do
          {:ok, link}
        else
          {:error, "invalid path"}
        end
      end)
    end
  end
end
