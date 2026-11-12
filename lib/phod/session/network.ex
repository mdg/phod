defmodule Phod.Session.Network do
  @moduledoc """
  A session's network connections, set when the session starts.

      %{
        http: %{"docs" => %{base_url: "http://docs.internal:8080", headers: ["Accept: text/markdown"], read_only: true}},
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
    http: [:base_url],
    postgres: [:host, :port, :database, :user, :password]
  }
  @optional %{
    http: [:headers, :read_only],
    postgres: [:read_only]
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
        allowed = @required[protocol] ++ @optional[protocol]
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
    headers = Map.get(fields, :headers, [])

    cond do
      bad ->
        {:error, {:invalid_connection, protocol, label, {:bad_field, bad}}}

      not is_boolean(read_only) ->
        {:error, {:invalid_connection, protocol, label, {:bad_field, :read_only}}}

      not valid_headers?(headers) ->
        {:error, {:invalid_connection, protocol, label, {:bad_field, :headers}}}

      true ->
        connection =
          fields
          |> Map.put(:read_only, read_only)
          |> Map.put(:headers, headers)
          |> Map.put(:label, label)

        {:ok, connection}
    end
  end

  defp valid_field?(:port, port), do: is_integer(port) and port in 1..65_535
  defp valid_field?(:password, password), do: is_binary(password)
  defp valid_field?(:base_url, url), do: valid_base_url?(url)
  defp valid_field?(_field, value), do: is_binary(value) and value != ""

  # The scheme and host, with at most a bare "/" as the path. The path and
  # query belong to each request, not to the connection.
  defp valid_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path in [nil, "", "/"]

      _invalid ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  # A list of "Name: value" strings, each with a name before the first colon.
  defp valid_headers?(headers) when is_list(headers) do
    Enum.all?(headers, fn header ->
      is_binary(header) and valid_header?(header)
    end)
  end

  defp valid_headers?(_headers), do: false

  defp valid_header?(header) do
    case String.split(header, ":", parts: 2) do
      [name, _value] -> String.trim(name) != ""
      _no_colon -> false
    end
  end

  @doc """
  Adds one connection to a normalised config. The connection is checked as a
  config entry is at start. Returns `{:error, :already_configured}` if the label
  is taken.
  """
  @spec add_connection(map(), atom(), String.t() | atom(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_connection(network, protocol, label, fields) do
    label = to_string(label)

    cond do
      Map.has_key?(Map.get(network, protocol, %{}), label) ->
        {:error, :already_configured}

      true ->
        case normalize(%{protocol => %{label => fields}}) do
          {:ok, one} ->
            {:ok, Map.update(network, protocol, one[protocol], &Map.merge(&1, one[protocol]))}

          {:error, _reason} = error ->
            error
        end
    end
  end

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

  @doc """
  One summary per connection, sorted by tool name, for listing. Never includes
  a password or a header value, only the names of the headers.
  """
  @spec summaries(map()) :: [map()]
  def summaries(network) do
    for {name, _module, connection} <- tools(network) do
      summary(name, connection)
    end
  end

  defp summary(name, %{base_url: base_url} = connection) do
    %{
      tool: name,
      protocol: :http,
      label: connection.label,
      read_only: connection.read_only,
      base_url: base_url,
      header_names: Enum.map(connection.headers, &(&1 |> String.split(":", parts: 2) |> hd()))
    }
  end

  defp summary(name, connection) do
    %{
      tool: name,
      protocol: :postgres,
      label: connection.label,
      read_only: connection.read_only,
      host: connection.host,
      port: connection.port,
      database: connection.database,
      user: connection.user
    }
  end

  @json_protocols %{"http" => :http, "postgres" => :postgres}
  @json_fields %{
    "base_url" => :base_url,
    "headers" => :headers,
    "read_only" => :read_only,
    "host" => :host,
    "port" => :port,
    "database" => :database,
    "user" => :user,
    "password" => :password
  }

  @doc """
  Reads a session's config file. A missing file is `{:ok, nil}` (no network).
  The result is the raw config, not yet checked: pass it to `normalize/1`.
  """
  @spec read_file(String.t()) :: {:ok, term()} | {:error, term()}
  def read_file(path) do
    case File.read(path) do
      {:ok, text} -> decode(text)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, from_json(map)}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  # JSON keys are strings. Protocol and field names map to atoms only when they
  # are known; anything else stays a string, which `normalize/1` rejects.
  defp from_json(map) do
    Map.new(map, fn {protocol, entries} ->
      {Map.get(@json_protocols, protocol, protocol), from_json_entries(entries)}
    end)
  end

  defp from_json_entries(entries) when is_map(entries) do
    Map.new(entries, fn {label, fields} -> {label, from_json_fields(fields)} end)
  end

  defp from_json_entries(entries), do: entries

  defp from_json_fields(fields) when is_map(fields) do
    Map.new(fields, fn {key, value} -> {Map.get(@json_fields, key, key), value} end)
  end

  defp from_json_fields(fields), do: fields

  @doc """
  Writes a normalised config to `path` as JSON. The file holds passwords, so it
  is readable only by its owner (0600). The write goes through a temp file, so
  a failed write doesn't leave a half-written config behind.
  """
  @spec write_file(String.t(), map()) :: :ok | {:error, term()}
  def write_file(path, network) do
    json = network |> to_json_map() |> Jason.encode!(pretty: true)
    temp = path <> ".tmp"

    with :ok <- File.write(temp, json),
         :ok <- File.chmod(temp, 0o600) do
      File.rename(temp, path)
    end
  end

  defp to_json_map(network) do
    Map.new(network, fn {protocol, connections} ->
      {Atom.to_string(protocol), Map.new(connections, fn {label, connection} -> {label, connection_json(connection)} end)}
    end)
  end

  defp connection_json(connection) do
    connection
    |> Map.delete(:label)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc "The connection labels per protocol, for a snapshot. No credentials."
  @spec labels(map()) :: %{http: [String.t()], postgres: [String.t()]}
  def labels(network) do
    Map.new(@protocols, fn {protocol, _module} ->
      {protocol, network |> Map.get(protocol, %{}) |> Map.keys() |> Enum.sort()}
    end)
  end
end
