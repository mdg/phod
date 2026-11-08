defmodule Phod.Tool.Reply do
  @moduledoc """
  Sends this run's final response to the session that sent the message being
  handled. Offered only in `:peer` mode. Calling it ends the run.
  """

  alias Phod.Tool
  alias Phod.Tool.Input

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "reply"

  @impl Tool.B
  def description,
    do: """
    Send your final response to the session that sent you this message. This \
    ends your run: the sender gets your text, and you don't take another turn.\
    """

  @impl Tool.B
  def params do
    [
      Input.string(:text, "Your final response to the sender.", required: true)
    ]
  end

  @impl Tool.B
  def run(%{text: text}, %{call: call}), do: call.({:reply, text})
end
