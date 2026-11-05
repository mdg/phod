defmodule Phod.Tool do
  @moduledoc """
  Registry of the agent's tools. Maps tool names (as the LLM knows them) to
  implementations and exposes LLM-facing tool specs.
  """

  import Rexult
  alias __MODULE__.Input

  @tools [
    __MODULE__.Grep,
    __MODULE__.ReadFile,
    __MODULE__.ListFiles,
    __MODULE__.Patch,
  ]

  @names Map.new(@tools, fn tool -> {tool.name(), tool} end)

  @spec all() :: [module()]
  def all, do: @tools

  @spec specs() ::
          [
            %{
              required(:name) => String.t(),
              required(:description) => String.t(),
              required(:input_schema) => map()
            }
          ]
  def specs do
    for tool <- @tools do
      %{name: tool.name(), description: tool.description(), input_schema: tool.input_schema()}
    end
  end

  @doc """
  Builds the `tools` array shape the Anthropic Messages API expects, from
  the registry — so callers never need their own copy of tool knowledge.
  """
  @spec anthropic_tools() :: [map()]
  def anthropic_tools do
    for %{name: name, description: description, input_schema: schema} <- specs() do
      %{"name" => name, "description" => description, "input_schema" => schema}
    end
  end

  @spec run(String.t(), String.t(), map()) :: __MODULE__.B.result()
  def run(name, root, input) do
    case Map.fetch(@names, name) do
      {:ok, tool} ->
        input
        |> Input.from_map(root)
        |> Input.validate_fields(tool.tool_fields())
        |> ok_and_then(&tool.run/1)

      :error ->
        {:error, "unknown tool: #{inspect(name)}"}
    end
  end
end
