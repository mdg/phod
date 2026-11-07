defmodule Phod.Session.TestHelpers do
  @moduledoc false

  # Shared helper for tests that drive a real Phod.Session GenServer against
  # the Req.Test-stubbed LLM: starting the session hands its agent-run Task
  # to a different pid than the test process, so the Req.Test stub ownership
  # must be explicitly allowed for that pid too.

  def start_and_allow(user, tree) do
    {:ok, pid} = Phod.Session.ensure_started(user, tree)
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)
    pid
  end
end
