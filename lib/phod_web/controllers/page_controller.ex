defmodule PhodWeb.PageController do
  use PhodWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
