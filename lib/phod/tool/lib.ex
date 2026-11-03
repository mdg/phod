defmodule Phod.Tool.Lib do
  @moduledoc """
  Shared filesystem helpers for tool implementations.

  Tools operate strictly inside the session worktree. Every tool receives the
  worktree root as its first argument and receives all paths in its input
  **relative to the worktree root**. Implementations must go through
  `Phod.Tool.Lib.resolve_path/3` before touching the filesystem — it validates that the path
  stays inside the worktree (rejecting `..`, absolute paths, and symlinks
  that escape). Worktrees live under `~/phod/tree/`; the bare repos under
  `~/phod/repo/` are never touched by tools.
  """

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

  With `allow_new?: true` (used by `apply_diff` when creating files) paths in
  not-yet-existing directories are accepted; the default requires the path or
  its parent to exist.
  """
  import Rexult

  @spec resolve_path(String.t(), term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(root, path, opts \\ [])

  def resolve_path(_root, path, _opts) when not is_binary(path) do
    {:error, "path must be a string, got: #{inspect(path)}"}
  end

  def resolve_path(_root, "", _opts) do
    {:error, "path must not be empty"}
  end

  def resolve_path(root, path, opts) do
    allow_new? = Keyword.get(opts, :allow_new?, false)

    if not File.dir?(root) do
      {:error, "invalid worktree root"}
    else
      Path.safe_relative(path, root)
      |> rexult()
      |> map_err(fn _ -> "invalid path" end)
      |> ok_and_then(fn safe_path ->
        if allow_new? or File.exists?(Path.join(root, safe_path)) do
          {:ok, safe_path}
        else
          {:error, "file does not exist"}
        end
      end)
    end
  end

  @doc """
  Formats a POSIX error reason into a human-readable message.
  """
  @spec format_error(atom() | String.t()) :: String.t()
  def format_error(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      charlist when is_list(charlist) -> List.to_string(charlist)
      text when is_binary(text) -> text
    end
  end

  def format_error(reason) when is_binary(reason), do: reason

  @doc """
  Splits a file's content into line strings, preserving whether the
  file ended with a newline. Used by both `read_file` (for numbered output) and
  `apply_diff` (for writing back atomically).
  """
  @spec read_lines(String.t()) :: {:ok, [String.t()], boolean()} | {:error, atom()}
  def read_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        trailing_newline? = String.ends_with?(content, "\n")
        content = if trailing_newline?, do: String.trim_trailing(content, "\n"), else: content
        {:ok, String.split(content, "\n"), trailing_newline?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes `lines` back to `path`, appending a trailing newline when
  `trailing_newline?` is true.
  """
  @spec write_lines(String.t(), [String.t()], boolean()) :: :ok | {:error, String.t()}
  def write_lines(path, lines, trailing_newline?) do
    content =
      lines
      |> Enum.join("\n")
      |> then(fn c -> if trailing_newline?, do: c <> "\n", else: c end)

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, format_error(reason)}
    end
  end
end
