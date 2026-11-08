defmodule Phod.Tool.Input.LinkPaths do
  @moduledoc """
  The LinkPaths input type: a non-empty list of paths, each validated as
  `Phod.Tool.Input.LinkPath` validates a single path, so a symlink in any
  entry's final component is kept rather than followed. Duplicates are dropped.
  """

  alias Phod.Tool.Input
  alias Phod.Tool.Input.LinkPath
  alias Phod.Tool.Input.Paths

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :link_paths

  @impl Input.Type
  def desc() do
    """
    A list of paths to files or symlinks in the repo, not followed
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
  Validate that the value is a non-empty list of link paths, each resolving
  inside the session root. Options as for `Phod.Tool.Input.LinkPath.validate/2`.
  """
  @impl Input.Type
  def validate(paths, opts), do: Paths.validate_with(paths, opts, &LinkPath.validate/2)
end
