defmodule Phod.Tool.Http do
  @moduledoc """
  An HTTP request to one configured connection (see `Phod.Session.Network`).
  The host and port come from the connection, never from the model's input.
  Redirects aren't followed. With `read_only: true` only GET is allowed.

  Not a `Phod.Tool.B` tool of its own: each connection is offered to the model
  as a tool named `http_<label>`, built by `Phod.Session.Network`.
  """

  alias Phod.Tool.{Input, Output}

  @timeout_ms 10_000
  @methods %{"GET" => :get, "POST" => :post, "PUT" => :put, "PATCH" => :patch, "DELETE" => :delete}

  @doc "The parameters the model fills in for a call."
  def params do
    [
      Input.string(:path, "The path on the server, starting with /.", required: true),
      Input.string(:method, "The HTTP method.", default: "GET"),
      Input.string(:query, "The query string, without the leading ?."),
      Input.string(:body, "The request body, for methods other than GET.")
    ]
  end

  @doc "What the model is told about this connection. The headers stay out of it: they may hold credentials."
  def describe(%{base_url: base_url, label: label, read_only: read_only}) do
    base = "Make an HTTP request to #{base_url} (connection http_#{label}). " <>
      "Paths are relative to that server."

    if read_only do
      base <> " Only GET is allowed."
    else
      base <> " GET, POST, PUT, PATCH, and DELETE are allowed."
    end
  end

  @doc "Runs a request, after checking it against the connection."
  def run(%{path: path, method: method} = args, %{connection: connection}) do
    method = String.upcase(method)

    cond do
      not String.starts_with?(path, "/") ->
        {:error, "path must start with /"}

      not Map.has_key?(@methods, method) ->
        {:error, "unsupported method #{method}"}

      connection.read_only and method != "GET" ->
        {:error, "http_#{connection.label} is read-only: only GET is allowed"}

      true ->
        request(args, method, connection)
    end
  end

  defp request(args, method, connection) do
    url = String.trim_trailing(connection.base_url, "/") <> args.path <> query(args)

    options =
      [method: @methods[method], url: url, redirect: false, retry: false,
       receive_timeout: @timeout_ms]
      |> maybe_put(:body, args[:body])
      |> Keyword.put(:headers, header_pairs(connection.headers))
      |> Keyword.merge(req_options())

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: Output.truncate(text(body))}}

      {:error, exception} ->
        {:error, "request failed: #{Exception.message(exception)}"}
    end
  end

  # "Name: value" strings, as Req takes them: {name, value} pairs.
  defp header_pairs(headers) do
    for header <- headers do
      [name, value] = String.split(header, ":", parts: 2)
      {String.trim(name), String.trim(value)}
    end
  end

  defp query(%{query: query}) when is_binary(query) and query != "", do: "?" <> query
  defp query(_args), do: ""

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp text(body) when is_binary(body), do: body
  defp text(body), do: Jason.encode!(body)

  defp req_options do
    :phod
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
