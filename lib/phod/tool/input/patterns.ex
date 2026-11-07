defmodule Phod.Tool.Input.Patterns do
  @moduledoc """
  The Patterns input type, a non-empty list of strings that are valid
  regular expressions
  """

  alias Phod.Tool.Input

  @behaviour Input.Type

  @impl Input.Type
  def name, do: :patterns

  @impl Input.Type
  def desc() do
    """
    A list of regular expressions. Matches are the union of all patterns.
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
  Validate that the input carries a non-empty list of non-empty strings, each
  of which compiles as a regular expression. The list shape is checked by
  `Phod.Tool.Input.validate(:patterns, input)`.
  """
  @impl Input.Type
  def validate(patterns, opts)

  def validate(patterns, _opts) when not is_list(patterns) do
    {:error, "invalid patterns"}
  end

  def validate([], _opts) do
    {:error, "invalid empty patterns"}
  end

  def validate(patterns, _opts) do
    if Enum.all?(patterns, &valid_pattern?/1) do
      {:ok, patterns}
    else
      {:error, "invalid params"}
    end
  end

  def valid_pattern?(pattern)

  def valid_pattern?(pattern) when not is_binary(pattern) do
    {:error, "invalid pattern"}
  end

  def valid_pattern?("") do
    {:error, "invalid empty pattern"}
  end

  def valid_pattern?(pattern) do
    case Regex.compile(pattern) do
      {:ok, _regex} -> true
      {:error, _reason} -> false
    end
  end
end
