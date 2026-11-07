defmodule Phod.Tool.Input.String do
  @moduledoc """
  The String input type, a non-blank string
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :string

  @impl Input.Type
  def desc() do
    """
    A non-blank string
    """
  end

  @impl Input.Type
  def schema_type() do
    "string"
  end

  @doc """
  Validate that the value is a string containing something other than
  whitespace
  """
  @impl Input.Type
  def validate(value, opts)

  def validate(value, _opts) when not is_binary(value) do
    {:error, "invalid string, got: #{inspect(value)}"}
  end

  def validate(value, _opts) do
    if String.trim(value) == "" do
      {:error, "invalid empty string"}
    else
      {:ok, value}
    end
  end
end
