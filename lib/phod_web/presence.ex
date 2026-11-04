defmodule PhodWeb.Presence do
  @moduledoc """
  Tracks who's connected to a session's `"sessions:<id>"` PubSub topic.

  Presence diffs share the same topic as `Phod.Session`'s raw
  `{:session_snapshot, _}` broadcasts; subscribers pattern-match on each
  message shape independently in `handle_info/2`.
  """

  use Phoenix.Presence,
    otp_app: :phod,
    pubsub_server: Phod.PubSub
end
