defmodule Phod.Tool.Input.Integer do
  @moduledoc """
  The Integer input type: a whole number, within `:min` and `:max` when the
  parameter sets them (`Phod.Tool.Input.integer/3`).
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :integer

  @impl Input.Type
  def desc() do
    """
    A whole number
    """
  end

  @impl Input.Type
  def schema_type() do
    "integer"
  end

  @doc """
  Validate that the value is an integer, within the `min` and `max` options
  when they're given.
  """
  @impl Input.Type
  def validate(value, opts)

  def validate(value, opts) when is_integer(value) do
    min = Map.get(opts, :min)
    max = Map.get(opts, :max)

    cond do
      min && value < min -> {:error, "must be at least #{min}, got #{value}"}
      max && value > max -> {:error, "must be at most #{max}, got #{value}"}
      true -> {:ok, value}
    end
  end

  def validate(value, _opts), do: {:error, "invalid integer, got: #{inspect(value)}"}
end
