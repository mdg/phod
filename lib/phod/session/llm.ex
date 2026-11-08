defmodule Phod.Session.Llm do
  @moduledoc """
  Req-based client for the Anthropic Messages API, as hosted by OpenCode
  Zen (`https://opencode.ai/zen/v1/messages`). Builds the `system` and
  `tools` parts of every request from a static system prompt and
  `Phod.Tool.anthropic_tools/0`, so callers only ever need to supply the
  conversation so far.
  """

  require Logger

  @system_prompt """
  You are a careful coding agent working inside a sandboxed git worktree. \
  Every path you pass to a tool is relative to the worktree root; you cannot \
  read or write anything outside it. Search with focus: make a few targeted \
  searches rather than surveying the whole project. Once you have enough to \
  act, make the change, then verify each edit by reading the file back. \
  If something the request names isn't in the code, don't keep searching for it. \
  After two or three searches, stop and report what you found, the closest match, \
  and what you propose. Never repeat a search that returned nothing; change the \
  angle or stop. If the task is ambiguous or you can't finish it, stop searching \
  and say what you found and what you propose instead. Each request has a limited \
  number of tool rounds, so don't spend them on searches you don't need. \
  Do not try to execute the generated code. \
  """

  @doc "The static system prompt sent with every request."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @type block :: map()
  @type message :: map()

  @doc """
  Calls the Messages API. `instructions` is the project's `AGENTS.md` text, or
  `nil` when the worktree has none. It goes in its own system block, marked
  for prompt caching, so repeated rounds of a run don't re-bill it. `tools`
  defaults to `Phod.Tool.anthropic_tools/0`. `tool_choice: :none` keeps the
  tools in the request, which the conversation needs, but stops the model
  calling them.
  """
  @spec complete([message()], String.t() | nil, [map()] | nil, keyword()) ::
          {:ok, %{content: [block()], stop_reason: String.t() | nil}} | {:error, String.t()}
  def complete(messages, instructions \\ nil, tools \\ nil, opts \\ []) do
    cfg = config()

    if cfg[:api_key] in [nil, ""] do
      {:error, "LLM_API_KEY is not set"}
    else
      body =
        %{
          "model" => cfg[:model],
          "system" => system_blocks(instructions),
          "messages" => messages,
          "tools" => tools || Phod.Tool.anthropic_tools(),
          "max_tokens" => cfg[:max_tokens],
          "stream" => false,
        }
        |> with_tool_choice(Keyword.get(opts, :tool_choice))

      cfg
      |> client()
      |> Req.post(url: "/v1/messages", headers: [{"x-api-key", cfg[:api_key]}], json: body)
      |> handle_response()
    end
  end

  defp system_blocks(nil), do: [text_block(@system_prompt)]

  defp system_blocks(instructions) do
    cached =
      ("Project instructions (AGENTS.md):\n\n" <> instructions)
      |> text_block()
      |> Map.put("cache_control", %{"type" => "ephemeral"})

    [text_block(@system_prompt), cached]
  end

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp with_tool_choice(body, :none), do: Map.put(body, "tool_choice", %{"type" => "none"})
  defp with_tool_choice(body, nil), do: body

  defp client(cfg) do
    Req.new([base_url: cfg[:base_url]] ++ cfg[:req_options])
  end

  defp config, do: Application.get_env(:phod, __MODULE__, [])

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:ok, %{content: body["content"] || [], stop_reason: body["stop_reason"]}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("LLM request failed (status #{status}): #{inspect(body)}")
    {:error, "LLM request failed (status #{status}): #{inspect(body)}"}
  end

  defp handle_response({:error, exception}) do
    Logger.error(
      "LLM request failed: #{Exception.message(exception)} (#{inspect(exception)})"
    )

    {:error, "LLM request failed: " <> Exception.message(exception)}
  end
end
