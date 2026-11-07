defmodule Phod.Tool.Input.Bool do
  @moduledoc """
  The Bool input type, accepting only JSON booleans (`true` / `false`)
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :bool

  @impl Input.Type
  def desc() do
    """
    A boolean parameter, either true or false
    """
  end

  @impl Input.Type
  def schema_type() do
    "boolean"
  end

  @doc """
  Validate that the value is a boolean
  """
  @impl Input.Type
  def validate(value, opts)

  def validate(value, _opts) when is_boolean(value) do
    {:ok, value}
  end

  def validate(value, _opts) do
    {:error, "invalid boolean, got: #{inspect(value)}"}
  end
end
