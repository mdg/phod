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
  read or write anything outside it. Investigate the code before editing, and \
  verify each edit by reading the file back. \
  Do not write tests or try to execute the generated code. \
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
  defaults to `Phod.Tool.anthropic_tools/0`.
  """
  @spec complete([message()], String.t() | nil, [map()] | nil) ::
          {:ok, %{content: [block()], stop_reason: String.t() | nil}} | {:error, String.t()}
  def complete(messages, instructions \\ nil, tools \\ nil) do
    cfg = config()

    if cfg[:api_key] in [nil, ""] do
      {:error, "LLM_API_KEY is not set"}
    else
      body = %{
        "model" => cfg[:model],
        "system" => system_blocks(instructions),
        "messages" => messages,
        "tools" => tools || Phod.Tool.anthropic_tools(),
        "max_tokens" => cfg[:max_tokens],
        "stream" => false
      }

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
    Logger.error("LLM request failed: #{Exception.message(exception)} (#{inspect(exception)})")
    {:error, "LLM request failed: " <> Exception.message(exception)}
  end
end
