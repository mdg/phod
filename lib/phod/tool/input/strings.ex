defmodule Phod.Tool.Input.Strings do
  @moduledoc """
  The Strings input type: a non-empty list of non-empty strings, such as a
  command and its arguments. A single string is not wrapped in a list here,
  since for a command the words matter, not just the one word.
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :strings

  @impl Input.Type
  def desc() do
    """
    A non-empty list of non-empty strings
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
  Validate that the value is a non-empty list of non-empty strings.
  """
  @impl Input.Type
  def validate(value, opts)

  def validate(value, _opts) when not is_list(value) do
    {:error, "invalid strings"}
  end

  def validate([], _opts) do
    {:error, "invalid empty strings"}
  end

  def validate(values, _opts) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "invalid empty string in list"}
    end
  end
end
