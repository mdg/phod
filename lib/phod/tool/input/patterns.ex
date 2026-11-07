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
  Validate that the value is a non-empty list of non-empty strings, each of
  which compiles as a regular expression. Reports the first bad entry.
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
    Enum.find_value(patterns, {:ok, patterns}, &check_pattern/1)
  end

  @doc """
  `nil` means the entry is fine, so `Enum.find_value/3` moves on to the next.
  """
  def check_pattern(pattern)

  def check_pattern("") do
    {:error, "invalid empty pattern"}
  end

  def check_pattern(pattern) when not is_binary(pattern) do
    {:error, "invalid pattern"}
  end

  def check_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, _regex} -> nil
      {:error, reason} -> {:error, "invalid regex #{inspect(pattern)}: #{inspect(reason)}"}
    end
  end
end
