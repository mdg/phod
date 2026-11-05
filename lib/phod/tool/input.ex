defmodule Phod.Tool.Input do
  @moduledoc """
  The input type for Tool calls
  """

  import Rexult

  @type t :: %{
          diff: String.t() | nil,
          path: String.t(),
          patterns: [String.t()],
          full_path: String.t() | nil,
          root: String.t(),
          allow_new_path?: boolean(),
          all: boolean()
        }

  defstruct diff: nil,
            path: ".",
            patterns: [],
            full_path: nil,
            root: ".",
            allow_new_path?: false,
            all: false

  def from_map(map, root) do
    fields =
      map
      |> Map.take(["diff", "path", "patterns", "all"])
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
      |> Map.put(:root, root)

    struct(__MODULE__, fields)
  end

  def validate_fields(input, fields) do
    Enum.reduce_while(fields, {:ok, input}, fn field, {:ok, acc} ->
      case validate(field, acc) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def validate(:diff, %__MODULE__{diff: diff}) when not is_binary(diff) do
    {:error, "invalid diff"}
  end

  def validate(:diff, %__MODULE__{} = input) do
    case String.trim(input.diff) do
      "" -> {:error, "cannot apply empty diff"}
      diff -> {:ok, %{input | diff: diff}}
    end
  end

  def validate(:allow_new_path, %__MODULE__{} = input) do
    {:ok, %{input | allow_new_path?: true}}
  end

  def validate(:all, %__MODULE__{all: all} = input) when is_boolean(all) do
    {:ok, input}
  end

  def validate(:all, %__MODULE__{}) do
    {:error, "invalid all"}
  end

  def validate(:path, %__MODULE__{path: path}) when not is_binary(path) do
    {:error, "invalid path"}
  end

  def validate(:path, %__MODULE__{root: root}) when not is_binary(root) do
    {:error, "invalid path root"}
  end

  def validate(:path, %__MODULE__{path: ""}) do
    {:error, "invalid empty path"}
  end

  def validate(:path, %__MODULE__{root: ""}) do
    {:error, "invalid empty path"}
  end

  def validate(:path, %__MODULE__{} = input) do
    resolve_path(input.root, input.path, input.allow_new_path?)
    |> map_ok(fn safe_path ->
      %{input | path: safe_path, full_path: Path.join(input.root, safe_path)}
    end)
  end

  def validate(:patterns, %__MODULE__{patterns: p}) when not is_list(p) do
    {:error, "invalid patterns"}
  end

  def validate(:patterns, %__MODULE__{patterns: []}) do
    {:error, "invalid empty patterns"}
  end

  def validate(:patterns, %__MODULE__{patterns: patterns} = input) do
    if Enum.all?(patterns, &(is_binary(&1) and &1 != "")) do
      {:ok, input}
    else
      {:error, "invalid empty patterns"}
    end
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

  With `allow_new_path?: true` (used by `apply_diff` when creating files) paths in
  not-yet-existing directories are accepted; the default requires the path or
  its parent to exist.
  """
  @spec resolve_path(String.t(), term(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(root, path, allow_new_path?)

  def resolve_path(_root, path, _) when not is_binary(path) do
    {:error, "path must be a string, got: #{inspect(path)}"}
  end

  def resolve_path(_root, "", _) do
    {:error, "path must not be empty"}
  end

  def resolve_path(root, path, allow_new?) do
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
