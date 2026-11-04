defmodule PhodWeb.SessionJoinController do
  @moduledoc """
  Sets the per-browser identity used by the Presence roster.

  A connected LiveView socket can't set cookies, so the "what's your name"
  prompt in `PhodWeb.SessionLive.Show` is a plain (non-`phx-submit`) HTML
  form that posts here, through a real Plug request, before redirecting
  back into the session.
  """

  use PhodWeb, :controller

  def create(conn, %{"owner" => owner, "tree" => tree} = params) do
    display_name =
      params
      |> Map.get("name", "")
      |> String.trim()
      |> case do
        "" -> "Anonymous"
        display_name -> display_name
      end

    client_id = get_session(conn, :client_id) || Ecto.UUID.generate()

    conn
    |> put_session(:display_name, display_name)
    |> put_session(:client_id, client_id)
    |> redirect(to: ~p"/sessions/#{owner}/#{tree}")
  end
end
