defmodule Phod.Session.Log do
  @moduledoc """
  Markdown log of a session's conversation, written beside the worktree.

  The log for a worktree at `<root>` lives at `<root>.md`, outside the
  worktree. It is reset when a session starts (with the system prompt at the
  top), then appended to as messages happen.

  Every entry is a `###` header with the sender ("phod" or the user's display
  name) and a timestamp in America/New_York, followed by its body. Bodies are
  fenced code blocks, so message text containing markdown cannot break the
  document. Long bodies are truncated.

  Writes are best-effort: `reset/2` and `append/2` return `{:error, reason}`
  rather than raising, and callers log the failure and carry on.
  """

  @max_body_bytes 4_000
  @timezone "America/New_York"

  @doc "The log path for a worktree root: the root with `.md` appended."
  @spec path(String.t()) :: String.t()
  def path(worktree_root), do: worktree_root <> ".md"

  @doc """
  Replaces the log with a fresh one containing only the system prompt.
  """
  @spec reset(String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def reset(path, system_prompt, now \\ DateTime.utc_now()) do
    header = "# Session log\n\n"
    write(path, [header, system_prompt_entry(system_prompt, now)], [:write])
  end

  @doc "Appends already-formatted entries (see `message_entries/2`) to the log."
  @spec append(String.t(), iodata()) :: :ok | {:error, term()}
  def append(path, entries), do: write(path, entries, [:append])

  @doc """
  The log entries for one conversation message, in order. Assistant messages
  yield one entry per text or tool-call block; user messages yield a sender
  entry for plain text, or a tool-result entry for each `tool_result` block.
  """
  @spec message_entries(map(), String.t(), DateTime.t()) :: [iodata()]
  def message_entries(message, user_name, now \\ DateTime.utc_now())

  def message_entries(%{"role" => "assistant", "content" => blocks}, _user_name, now) do
    Enum.flat_map(blocks, fn
      %{"type" => "text", "text" => text} ->
        [entry("phod", now, [fence(text, "text")])]

      %{"type" => "tool_use", "name" => name, "input" => input} = block ->
        id = Map.get(block, "id", "")

        [
          entry("phod", now, [
            "**tool call:** `",
            name,
            "` · id `",
            id,
            "`\n\n",
            fence(json(input), "json")
          ])
        ]

      _other ->
        []
    end)
  end

  def message_entries(%{"role" => "user", "content" => blocks}, user_name, now) do
    Enum.map(blocks, fn
      %{"type" => "tool_result"} = block ->
        label = if block["is_error"], do: "tool error", else: "tool result"
        id = Map.get(block, "tool_use_id", "")

        entry("phod", now, [
          "**",
          label,
          ":** · id `",
          id,
          "`\n\n",
          fence(block["content"] || "", "text")
        ])

      %{"type" => "text", "text" => text} ->
        entry(user_name, now, [fence(text, "text")])
    end)
  end

  @doc "An entry recording why an agent run failed, so a stopped run is visible in the log."
  @spec error_entry(String.t(), DateTime.t()) :: iodata()
  def error_entry(reason, now \\ DateTime.utc_now()) do
    entry("phod", now, ["**run error:**\n\n", fence(reason, "text")])
  end

  @doc "A sender entry for a user's message as it was sent."
  @spec user_entry(String.t(), String.t(), DateTime.t()) :: iodata()
  def user_entry(user_name, text, now \\ DateTime.utc_now()) do
    entry(user_name, now, [fence(text, "text")])
  end

  @doc """
  Formats a timestamp in America/New_York, e.g. `2026-11-06 11:03:29 EST`.
  """
  @spec timestamp(DateTime.t()) :: String.t()
  def timestamp(now) do
    now
    |> DateTime.shift_zone!(@timezone)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S %Z")
  end

  # Entries ---------------------------------------------------------------

  defp system_prompt_entry(system_prompt, now) do
    entry("phod", now, ["**system prompt:**\n\n", fence(system_prompt, "text")])
  end

  defp entry(sender, now, body) do
    ["### ", sender, " · ", timestamp(now), "\n\n", body, "\n\n"]
  end

  defp json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, text} -> text
      {:error, _} -> inspect(value)
    end
  end

  # Fencing and truncation -------------------------------------------------

  # The fence is always longer than any run of backticks in the content, so
  # the content cannot close the block early.
  @doc false
  def fence(content, lang) do
    content = truncate(content)
    ticks = String.duplicate("`", max(3, longest_backtick_run(content) + 1))
    [ticks, lang, "\n", content, "\n", ticks]
  end

  defp longest_backtick_run(content) do
    ~r/`+/
    |> Regex.scan(content)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  @doc false
  def truncate(content) when byte_size(content) <= @max_body_bytes, do: content

  def truncate(content) do
    kept = content |> binary_part(0, @max_body_bytes) |> valid_utf8_prefix()

    kept <>
      "\n… [truncated: showing #{byte_size(kept)} of #{byte_size(content)} bytes]"
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp write(path, data, modes) do
    File.write(path, data, modes)
  end
end
