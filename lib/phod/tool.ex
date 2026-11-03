defmodule Phod.Tool do
  @moduledoc """
  Registry of the agent's tools. Maps tool names (as the LLM knows them) to
  implementations and exposes LLM-facing tool specs.
  """

  import Rexult
  alias __MODULE__.Input

  @tools [
    __MODULE__.ApplyDiff,
    __MODULE__.GitGrep,
    __MODULE__.ReadFile,
    __MODULE__.ListFiles
  ]

  @names Map.new(@tools, fn tool -> {tool.name(), tool} end)

  @spec all() :: [module()]
  def all, do: @tools

  @spec specs() :: [%{required(:name) => atom(), required(:description) => String.t()}]
  def specs do
    for tool <- @tools do
      %{name: tool.name(), description: tool.description()}
    end
  end

  @spec run(atom(), String.t(), map()) :: __MODULE__.B.result()
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
