defmodule Phod.Tool.Send do
  @moduledoc """
  Sends a prompt to a connected peer session, starting an exchange. Offered only
  in `:user` mode, and only when the session has peers. The loop calls `run/2`
  with the session's peers and a `call` function that does the delivery.
  """

  alias Phod.Tool
  alias Phod.Tool.Input

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "send"

  @impl Tool.B
  def description,
    do: """
    Send a prompt to a connected peer session, which carries it out in its own \
    worktree. The peer gets the prompt as a message from this session. If the \
    peer is busy, the message waits in its queue, and the result says so. Set \
    want_reply to true to wait for the peer's final reply; with false, the peer \
    is not asked to reply.\
    """

  @impl Tool.B
  def params do
    [
      Input.string(:peer, "The peer session to send to.", required: true),
      Input.string(:prompt, "What the peer should do.", required: true),
      Input.bool(:want_reply, "Whether to wait for the peer's final reply.", default: false)
    ]
  end

  @impl Tool.B
  def run(%{peer: peer, prompt: prompt, want_reply: want_reply}, %{peers: peers, call: call}) do
    if peer in peers do
      call.({:send, peer, prompt, want_reply})
    else
      {:error, "peer #{peer} is not connected to this session"}
    end
  end
end
