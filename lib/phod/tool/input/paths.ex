defmodule Phod.Tool.Input.Paths do
  @moduledoc """
  The Paths input type: a non-empty list of paths, each validated exactly as
  `Phod.Tool.Input.Path` validates a single path. Duplicates are dropped.
  """

  alias Phod.Tool.Input
  alias Phod.Tool.Input.Path, as: PathInput

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :paths

  @impl Input.Type
  def desc() do
    """
    A list of paths to local files in the repo
    """
  end

  @impl Input.Type
  def schema_type() do
    "array"
  end

  @doc """
  The type of each array element in the schema
  """
  def item_type() do
    "string"
  end

  @doc """
  Validate that the value is a non-empty list of paths, each resolving inside
  the session root. Returns the resolved paths in order, without duplicates.
  Options are those `Phod.Tool.Input.Path.validate/2` needs (`session_root`).
  """
  @impl Input.Type
  def validate(paths, opts)

  def validate(paths, _opts) when not is_list(paths) do
    {:error, "invalid paths"}
  end

  def validate([], _opts) do
    {:error, "invalid empty paths"}
  end

  def validate(paths, opts) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case PathInput.validate(path, opts) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _msg} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _msg} = error -> error
    end
  end
end
