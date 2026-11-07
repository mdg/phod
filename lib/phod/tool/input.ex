defmodule Phod.Tool.Input do
  @moduledoc """
  The input type for Tool calls
  """

  alias __MODULE__.Param

  defdelegate required(param), to: Param

  defdelegate optional(param, default_val), to: Param

  @doc """
  A JSON Schema (string-keyed) describing this tool's LLM-facing input,
  e.g. `%{"type" => "object", "properties" => %{...}, "required" => [...]}`.

  Only fields the LLM actually supplies belong here. Internal capability
  flags consumed by `Phod.Tool.Input.validate/2` (such as `patch`'s
  `:allow_new_path`) are not real inputs and must not appear in this schema.
  """
  @spec to_schema([Param.t()]) :: map()
  def to_schema(params) do
    props =
      params
      |> Enum.map(fn param ->
        schema = Param.to_schema(param)
        {param.type.name(), schema}
      end)
      |> Map.new()

    required =
      params
      |> Enum.filter(& &1.required?)
      |> Enum.map(& &1.name)

    %{
      type: "object",
      properties: props,
      required: required,
    }
  end

  def to_map(params) do
    params
    |> Map.new(fn param ->
      {Atom.to_string(param.type.name()), param}
    end)
  end

  @doc """
  Shorthand for default single, required path parameter

  See path/4 for more options
  """
  def path(opts \\ []) do
    path(:path, nil, [{:required, true} | opts])
  end

  @doc """
  A path parameter

  opts:
  required bool
  """
  def path(name, desc, opts \\ []) do
    %Param{
      type: __MODULE__.Path,
      name: name,
      desc: desc,
      required?: Keyword.get(opts, :required, false),
      opts: Keyword.drop(opts, [:required]),
    }
  end

  @doc """
  A boolean parameter

  opts:
  required bool
  """
  def bool(name, desc, opts \\ []) do
    %Param{
      type: __MODULE__.Bool,
      name: name,
      desc: desc,
      required?: Keyword.get(opts, :required, false),
    }
  end

  @doc """
  A string parameter

  opts:
  required bool
  """
  def string(name, desc, opts \\ []) do
    %Param{
      type: __MODULE__.String,
      name: name,
      desc: desc,
      required?: Keyword.get(opts, :required, false),
      opts: Keyword.drop(opts, [:required]),
    }
  end

  @doc """
  A diff parameter

  opts:
  required bool
  """
  def diff() do
    %Param{
      type: __MODULE__.Diff,
      name: :diff,
      desc: "A unified diff to apply to the file.",
      required?: true,
    }
  end

  @doc """
  Shorthand for default single, required patterns parameter

  See patterns/3 for more options
  """
  def patterns(opts \\ []) do
    patterns(:patterns, nil, [{:required, true} | opts])
  end

  @doc """
  A list of regular expression patterns

  opts:
  required bool
  """
  def patterns(name, desc, opts \\ []) do
    %Param{
      type: __MODULE__.Patterns,
      name: name,
      desc: desc,
      required?: Keyword.get(opts, :required, false),
      opts: Keyword.drop(opts, [:required]),
    }
  end

  @doc """
  Validates the parameter values the LLM sent, one per declared param.

  `input` is the LLM's map of arguments (string keys, as in JSON). Each
  param's value is passed to its type's `validate/2`. Returns
  `{:ok, %{name => value}}` keyed by param name, or the first error.
  Optional params the LLM omitted come back as `nil`.
  """
  @spec validate_params(map(), [Param.t()], map()) :: Rexult.t()
  def validate_params(%{} = input, params, %{} = session_opts) when is_list(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn param, {:ok, acc} ->
      case validate_param(input, param, session_opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
        {:error, _msg} = error -> {:halt, error}
      end
    end)
  end

  defp validate_param(input, %Param{} = param, session_opts) do
    case Map.get(input, Atom.to_string(param.name)) do
      nil when param.required? -> {:error, "#{param.name} is required"}
      nil -> {:ok, nil}
      value -> param.type.validate(value, Map.merge(Map.new(param.opts), session_opts))
    end
  end
end
