defmodule Phod.Tool.Input.Path do
  @moduledoc """
  The Path input type to make sure that the local file is in the worktree.

  Symlinks are followed: a path to a link resolves to the file it points to,
  as long as that file is inside the worktree. Use `Phod.Tool.Input.LinkPath`
  to act on a symlink itself.
  """

  import Rexult

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :path

  @impl Input.Type
  def desc() do
    """
    A path parameter pointing to a local file in the repo
    """
  end

  @impl Input.Type
  def schema_type() do
    "string"
  end

  @doc """
  Validate that the path is valid and contained within the root. Options:
  `session_root` (required) and `allow_new_path` (see `resolve/3`).
  """
  @impl Input.Type
  def validate(path, opts) do
    case check_input(path, opts) do
      :ok -> resolve(opts.session_root, path, Map.get(opts, :allow_new_path, false))
      {:error, _msg} = error -> error
    end
  end

  @doc """
  Checks the value and options before any filesystem lookup: `path` must be a
  non-empty string, and `opts` must carry a non-empty `session_root` string.
  Shared with `Phod.Tool.Input.LinkPath`.
  """
  @spec check_input(term(), term()) :: :ok | {:error, String.t()}
  def check_input(path, _opts) when not is_binary(path), do: {:error, "invalid path"}
  def check_input("", _opts), do: {:error, "invalid empty path"}
  def check_input(_path, %{session_root: root}) when not is_binary(root), do: {:error, "invalid session_root"}
  def check_input(_path, %{session_root: ""}), do: {:error, "invalid empty session_root"}
  def check_input(_path, opts) when is_map(opts) and not is_map_key(opts, :session_root), do: {:error, "missing session_root"}
  def check_input(_path, opts) when is_map(opts), do: :ok
  def check_input(_path, _opts), do: {:error, "missing session_root"}

  @git_refusal "refusing to access .git"

  @doc """
  True when any component of `path` is `.git`. No tool may read or write
  inside the git directory, so every path type refuses these after
  resolution.
  """
  @spec git_path?(String.t()) :: boolean()
  def git_path?(path), do: ".git" in Path.split(path)

  @doc """
  Resolves `path` (relative to the worktree `root`) into a checked filesystem
  path, guaranteed to stay within `root`.

  `Path.safe_relative/2` is applied first: it collapses `..` and rejects
  absolute paths and traversal pointing outside `root`. The safe path is then
  walked component by component, resolving symlinks, so each existing
  component is verified to remain inside the worktree; non-existent
  components (e.g. files about to be created) are not yet resolvable but
  their container is, so they can never pre-emptively escape through a
  symlink.

  With `allow_new_path?: true` (used by `patch` when creating files) paths in
  not-yet-existing directories are accepted; the default requires the path or
  its parent to exist.
  """
  @spec resolve(String.t(), term(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(root, path, allow_new_path?)

  def resolve(_root, path, _allow_new?) when not is_binary(path) do
    {:error, "path must be a string, got: #{inspect(path)}"}
  end

  def resolve(_root, "", _allow_new?) do
    {:error, "path must not be empty"}
  end

  def resolve(root, path, allow_new?) do
    if not File.dir?(root) do
      {:error, "invalid worktree root"}
    else
      Path.safe_relative(path, root)
      |> rexult()
      |> map_err(fn _ -> "invalid path" end)
      |> ok_and_then(fn safe_path ->
        cond do
          git_path?(safe_path) -> {:error, @git_refusal}
          allow_new? or File.exists?(Path.join(root, safe_path)) -> {:ok, if(safe_path == "", do: ".", else: safe_path)}
          true -> {:error, "invalid path"}
        end
      end)
    end
  end
end
