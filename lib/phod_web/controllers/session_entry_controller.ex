defmodule PhodWeb.SessionEntryController do
  @moduledoc """
  Starts (idempotently) the one hardcoded session and sends the browser
  straight to it.

  There's no multi-session UI yet — picking a session isn't something to
  ask the user for until that exists, so `@session_id` is hardcoded here
  rather than coming from a form.
  """

  use PhodWeb, :controller

  @session_id "mdg/lucky"
  @owner "mdg"
  @tree "lucky"

  def new(conn, _params) do
    Phod.Session.ensure_started(@session_id, Phod.Session.worktree_root(@session_id))
    redirect(conn, to: ~p"/sessions/#{@owner}/#{@tree}")
  end
end
