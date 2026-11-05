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
  You have five tools available: list_files, read_file, grep, apply_diff, \
  and elixir_script. Every path you pass to a tool is relative to the \
  worktree root; you cannot read or write anything outside it. Investigate \
  with list_files, read_file, and grep before editing, and verify \
  apply_diff results by following up with read_file. Use elixir_script \
  for anything the other tools can't express - it runs an Elixir script \
  in its own OS sandbox with the worktree mounted read-write and no \
  network access.\
  """

  @type block :: map()
  @type message :: map()

  @spec complete([message()]) ::
          {:ok, %{content: [block()], stop_reason: String.t() | nil}} | {:error, String.t()}
  def complete(messages) do
    cfg = config()

    if cfg[:api_key] in [nil, ""] do
      {:error, "LLM_API_KEY is not set"}
    else
      body = %{
        "model" => cfg[:model],
        "system" => @system_prompt,
        "messages" => messages,
        "tools" => Phod.Tool.anthropic_tools(),
        "max_tokens" => cfg[:max_tokens],
        "stream" => false
      }

      cfg
      |> client()
      |> Req.post(url: "/v1/messages", headers: [{"x-api-key", cfg[:api_key]}], json: body)
      |> handle_response()
    end
  end

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
