defmodule Phod.Tool.Input.Diff do
  @moduledoc """
  The Diff input type, a non-empty diff to apply to the worktree
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :diff

  @impl Input.Type
  def desc() do
    """
    A diff to apply to files in the repo
    """
  end

  @impl Input.Type
  def schema_type() do
    "string"
  end

  @doc """
  Validate that the input carries a non-blank diff, returning it trimmed
  """
  @impl Input.Type
  def validate(input, opts)

  def validate(diff, _opts) when not is_binary(diff) do
    {:error, "invalid diff"}
  end

  def validate(diff, _opts) do
    case String.trim(diff) do
      "" -> {:error, "cannot apply empty diff"}
      diff -> {:ok, diff}
    end
  end
end
