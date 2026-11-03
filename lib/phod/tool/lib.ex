defmodule Phod.Tool.Lib do
  @moduledoc """
  Shared filesystem helpers for tool implementations.

  Tools operate strictly inside the session worktree. Every tool receives the
  worktree root as its first argument and receives all paths in its input
  **relative to the worktree root**. Implementations must go through
  `resolve/3` before touching the filesystem — it validates that the path
  stays inside the worktree (rejecting `..`, absolute paths, and symlinks
  that escape). Worktrees live under `~/phod/tree/`; the bare repos under
  `~/phod/repo/` are never touched by tools.
  """

  @doc """
  Resolves `path` (relative to the worktree `root`) into a checked filesystem
  path, guaranteed to stay within `root`.

  Walks the path component by component, resolving symlinks, so each existing
  component is verified to remain inside the worktree; non-existent components
  (e.g. files about to be created) are not yet resolvable but their container
  is, so they can never pre-emptively escape through a symlink.

  With `allow_new?: true` (used by `apply_diff` when creating files) paths in
  not-yet-existing directories are accepted; the default requires the path or
  its parent to exist. Rejects absolute paths and `..` traversal.
  """
  @spec resolve(String.t(), term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(root, path, opts \\ []) do
    allow_new? = Keyword.get(opts, :allow_new?, false)

    cond do
      not is_binary(path) ->
        {:error, "path must be a string, got: #{inspect(path)}"}

      path == "" ->
        {:error, "path must not be empty"}

      Path.type(path) == :absolute ->
        {:error, "path must be relative to the worktree root, got: #{inspect(path)}"}

      true ->
        case realpath(root) do
          {:ok, root} ->
            joined = Path.expand(path, root)

            if under?(root, joined) do
              rel = Path.relative_to(joined, root)
              parts = if rel == ".", do: [], else: Path.split(rel)

              do_walk(root, root, parts)
              |> validate(joined, path, allow_new?)
            else
              {:error, "path escapes the worktree root: #{inspect(path)}"}
            end

          {:error, reason} ->
            {:error, "invalid worktree root: " <> format_error(reason)}
        end
    end
  end

  defp under?(root, path) do
    root == path or String.starts_with?(path, root <> "/")
  end

  defp validate({:ok, candidate}, joined, original, allow_new?) do
    if allow_new? or File.exists?(candidate) or File.exists?(Path.dirname(candidate)) do
      {:ok, joined}
    else
      {:error, "invalid worktree path #{inspect(original)}: no such file or directory"}
    end
  end

  defp validate({:error, :escapes}, _joined, original, _allow_new?) do
    {:error, "path escapes the worktree root: #{inspect(original)}"}
  end

  defp validate({:error, reason}, _joined, original, _allow_new?) do
    {:error, "invalid worktree path #{inspect(original)}: " <> format_error(reason)}
  end

  # Walks each component; existing components are realpath'd and verified to
  # stay in the worktree. Returns the resolved path of the deepest existing
  # component (missing trailing components are joined as-is).
  defp do_walk(root, base, [part | rest]) do
    candidate = Path.join(base, part)

    if File.exists?(candidate) do
      case realpath(candidate) do
        {:ok, real} ->
          if under?(root, real) do
            do_walk(root, real, rest)
          else
            {:error, :escapes}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      # component does not exist (yet): assume it will be created in place,
      # joining the remainder in one step
      {:ok, Path.join([base, part | rest])}
    end
  end

  defp do_walk(_root, base, []), do: {:ok, base}

  # Resolves symlinks in `path`. Unlike the shell's `realpath`, a trailing
  # non-existent component is acceptable: its parent is resolved instead, so
  # new files can never be created through an escaping symlink.
  defp realpath(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if Path.type(target) == :absolute do
          realpath(target)
        else
          realpath(Path.expand(target, Path.dirname(path)))
        end

      # not a symlink: it is itself the real path
      {:error, :einval} ->
        {:ok, path}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the relative path of `absolute` within the worktree `root`.
  Used for presenting tool results back to the LLM.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(root, absolute) do
    case realpath(root) do
      {:ok, root} -> Path.relative_to(absolute, root)
      {:error, _} -> absolute
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
