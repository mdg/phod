defmodule Phod.Tool.Input.Path do
  @moduledoc """
  The Path input type to make sure that the local file is in the worktree
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
  Validate that the path is valid and contained within the root
  """
  @impl Input.Type
  def validate(path, opts)

  def validate(path, _opts) when not is_binary(path) do
    {:error, "invalid path"}
  end

  def validate("", _opts) do
    {:error, "invalid empty path"}
  end

  def validate(_path, %{session_root: root}) when not is_binary(root) do
    {:error, "invalid session_root"}
  end

  def validate(_path, %{session_root: ""}) do
    {:error, "invalid empty session_root"}
  end

  def validate(_path, opts) when not is_map_key(opts, :session_root) do
    {:error, "missing session_root"}
  end

  def validate(path, %{session_root: root} = opts) do
    allow_new_path? = Map.get(opts, :allow_new_path, false)

    resolve(root, path, allow_new_path?, follow_last?)
  end

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

  def resolve(_root, path, _) when not is_binary(path) do
    {:error, "path must be a string, got: #{inspect(path)}"}
  end

  def resolve(_root, "", _) do
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
        if allow_new? or File.exists?(Path.join(root, safe_path)) do
          {:ok, if(safe_path == "", do: ".", else: safe_path)}
        else
          {:error, "invalid path"}
        end
      end)
    end
  end
end
