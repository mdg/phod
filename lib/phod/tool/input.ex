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
        {param.name(), schema}
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
  def path() do
    path(:path, nil, required: true)
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

  def validate_params(%{} = input, params, %{} = session_opts) when is_list(params) do
    params
    |> Enum.map(fn %{name: name} = param ->
      input_val = Map.get(input, name)

      if input_val == nil and param.required? do
        {:error, "#{name} is required"}
      else
        opts = Map.merge(input.opts, session_opts)
        param.type.validate(input, opts)
      end
    end)
  end

  def validate(:diff, %__MODULE__{diff: diff}) when not is_binary(diff) do
    {:error, "invalid diff"}
  end

  def validate(:diff, %__MODULE__{} = input) do
    case String.trim(input.diff) do
      "" -> {:error, "cannot apply empty diff"}
      diff -> {:ok, %{input | diff: diff}}
    end
  end

  def validate(:script, %__MODULE__{script: script}) when not is_binary(script) do
    {:error, "invalid script"}
  end

  def validate(:script, %__MODULE__{} = input) do
    case String.trim(input.script) do
      "" -> {:error, "cannot run empty script"}
      script -> {:ok, %{input | script: script}}
    end
  end

  def validate(:patterns, %__MODULE__{patterns: p}) when not is_list(p) do
    {:error, "invalid patterns"}
  end

  def validate(:patterns, %__MODULE__{patterns: []}) do
    {:error, "invalid empty patterns"}
  end

  def validate(:patterns, %__MODULE__{patterns: patterns} = input) do
    if Enum.all?(patterns, &(is_binary(&1) and &1 != "")) do
      {:ok, input}
    else
      {:error, "invalid empty patterns"}
    end
  end
end
