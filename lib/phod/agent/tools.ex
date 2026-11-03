defmodule Phod.Agent.Tools do
  @moduledoc """
  Registry of the agent's tools. Maps tool names (as the LLM knows them) to
  implementations and exposes LLM-facing tool specs.
  """

  alias Phod.Agent.Tool

  @tools [
    Phod.Agent.Tool.ListFiles,
    Phod.Agent.Tool.ReadFile,
    Phod.Agent.Tool.GitGrep,
    Phod.Agent.Tool.ApplyDiff
  ]

  @names @tools |> Map.new(fn tool -> {tool.name(), tool} end)

  @spec all() :: [module()]
  def all, do: @tools

  @spec specs() :: [%{required(:name) => String.t(), required(:description) => String.t()}]
  def specs do
    for tool <- @tools do
      %{name: tool.name(), description: tool.description()}
    end
  end

  @spec run(String.t(), String.t(), Tool.input()) :: Tool.result()
  def run(name, root, input) do
    case Map.fetch(@names, name) do
      {:ok, tool} -> tool.run(root, input)
      :error -> {:error, "unknown tool: #{inspect(name)}"}
    end
  end
end
