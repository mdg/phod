defmodule Phod.Session.Network do
  @moduledoc """
  A session's network connections, set when the session starts.

      %{
        http: %{"docs" => %{host: "docs.internal", port: 8080, read_only: true}},
        postgres: %{
          "analytics" => %{host: "db.internal", port: 5432, database: "app",
                           user: "reader", password: "...", read_only: true}
        }
      }

  Each connection has a label, which becomes its tool's name: the `http` entry
  `"docs"` is the tool `http_docs`. Labels are lowercase letters, digits, and
  underscores, starting with a letter. `read_only` defaults to `true`. A protocol
  with no entries has no tools in the session.

  Credentials stay here: nothing in a snapshot or a tool description shows them.
  """

  alias Phod.Tool
  alias Phod.Tool.{Http, Input, Postgres}

  @protocols %{http: Http, postgres: Postgres}
  @required %{
    http: [:host, :port],
    postgres: [:host, :port, :database, :user, :password]
  }
  @label ~r/\A[a-z][a-z0-9_]*\z/

  @doc "A session with no network connections."
  @spec empty() :: map()
  def empty, do: %{http: %{}, postgres: %{}}

  @doc """
  Checks and fills in a network config (a map or keyword list). Returns the
  normalised config, or `{:error, reason}` naming the first problem.
  """
  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(nil), do: {:ok, empty()}

  def normalize(config) when is_map(config) or is_list(config) do
    config = Map.new(config)
    unknown = Map.keys(config) -- Map.keys(@protocols)

    if unknown == [] do
      Enum.reduce_while(@protocols, {:ok, empty()}, fn {protocol, _module}, {:ok, acc} ->
        case connections(protocol, Map.get(config, protocol, %{})) do
          {:ok, connections} -> {:cont, {:ok, Map.put(acc, protocol, connections)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:unknown_protocols, unknown}}
    end
  end

  def normalize(_config), do: {:error, :invalid_network}

  defp connections(protocol, entries) when is_map(entries) or is_list(entries) do
    entries
    |> Map.new()
    |> Enum.reduce_while({:ok, %{}}, fn {label, fields}, {:ok, acc} ->
      label = to_string(label)

      case connection(protocol, label, fields) do
        {:ok, connection} -> {:cont, {:ok, Map.put(acc, label, connection)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp connections(protocol, _entries), do: {:error, {:invalid_connections, protocol}}

  defp connection(protocol, label, fields) do
    cond do
      not Regex.match?(@label, label) ->
        {:error, {:invalid_label, protocol, label}}

      not is_map(fields) and not is_list(fields) ->
        {:error, {:invalid_connection, protocol, label, :not_a_map}}

      true ->
        fields = Map.new(fields)
        allowed = @required[protocol] ++ [:read_only]
        unknown = Map.keys(fields) -- allowed
        missing = @required[protocol] -- Map.keys(fields)

        cond do
          unknown != [] -> {:error, {:invalid_connection, protocol, label, {:unknown, unknown}}}
          missing != [] -> {:error, {:invalid_connection, protocol, label, {:missing, missing}}}
          true -> check_fields(protocol, label, fields)
        end
    end
  end

  defp check_fields(protocol, label, fields) do
    bad =
      Enum.find(@required[protocol], fn field ->
        not valid_field?(field, Map.fetch!(fields, field))
      end)

    read_only = Map.get(fields, :read_only, true)

    cond do
      bad ->
        {:error, {:invalid_connection, protocol, label, {:bad_field, bad}}}

      not is_boolean(read_only) ->
        {:error, {:invalid_connection, protocol, label, {:bad_field, :read_only}}}

      true ->
        {:ok, fields |> Map.put(:read_only, read_only) |> Map.put(:label, label)}
    end
  end

  defp valid_field?(:port, port), do: is_integer(port) and port in 1..65_535
  defp valid_field?(:password, password), do: is_binary(password)
  defp valid_field?(_field, value), do: is_binary(value) and value != ""

  @doc """
  The tools for a normalised config, as `{name, module, connection}`, sorted by
  name.
  """
  @spec tools(map()) :: [{String.t(), module(), map()}]
  def tools(network) do
    for {protocol, module} <- @protocols,
        {label, connection} <- Map.get(network, protocol, %{}) do
      {"#{protocol}_#{label}", module, connection}
    end
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Tool specs (in the Messages API shape) for the tools from `tools/1`."
  @spec specs([{String.t(), module(), map()}]) :: [map()]
  def specs(tools) do
    for {name, module, connection} <- tools do
      %{
        "name" => name,
        "description" => module.describe(connection),
        "input_schema" => Input.to_schema([Tool.goal_param() | module.params()])
      }
    end
  end

  @doc "The connection labels per protocol, for a snapshot. No credentials."
  @spec labels(map()) :: %{http: [String.t()], postgres: [String.t()]}
  def labels(network) do
    Map.new(@protocols, fn {protocol, _module} ->
      {protocol, network |> Map.get(protocol, %{}) |> Map.keys() |> Enum.sort()}
    end)
  end
end
