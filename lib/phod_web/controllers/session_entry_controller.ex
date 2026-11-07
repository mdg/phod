defmodule PhodWeb.SessionEntryController do
  @moduledoc """
  Starts (idempotently) the one hardcoded session and sends the browser
  straight to it.

  There's no multi-session UI yet — picking a session isn't something to
  ask the user for until that exists, so the owner and tree are hardcoded
  here rather than coming from a form.
  """

  use PhodWeb, :controller

  @owner "mdg"
  @tree "lucky"

  def new(conn, _params) do
    Phod.Session.ensure_started(@owner, @tree)
    redirect(conn, to: ~p"/sessions/#{@owner}/#{@tree}")
  end
end
