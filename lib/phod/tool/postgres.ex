defmodule Phod.Tool.Postgres do
  @moduledoc """
  SQL against one configured Postgres connection (see `Phod.Session.Network`).

  With `read_only: true` each statement runs in a read-only transaction, so the
  database refuses writes whatever the SQL says. Use a database role with only
  the rights you want as well: this check is a backstop, not the only defence.

  Each call opens its own connection and closes it afterwards. Not a
  `Phod.Tool.B` tool of its own: each connection is offered to the model as a
  tool named `postgres_<label>`, built by `Phod.Session.Network`.
  """

  alias Phod.Tool.{Input, Output}

  @timeout_ms 10_000
  @max_rows 100

  @doc "The parameters the model fills in for a call."
  def params do
    [Input.string(:sql, "A single SQL statement.", required: true)]
  end

  @doc "What the model is told about this connection."
  def describe(%{host: host, port: port, database: database, label: label, read_only: read_only}) do
    base = "Run SQL on the #{database} database at #{host}:#{port} (connection " <>
      "postgres_#{label}). Results come back as columns and up to #{@max_rows} rows."

    if read_only do
      base <> " Runs in a read-only transaction, so writes are refused."
    else
      base <> " Writes are allowed."
    end
  end

  @doc "Runs a statement on the connection. The work happens in a task, so a stuck connection can't hang the run."
  def run(%{sql: sql}, %{connection: connection}) do
    task =
      Task.Supervisor.async_nolink(Phod.Session.TaskSupervisor, fn ->
        query(connection, sql)
      end)

    case Task.yield(task, @timeout_ms + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "postgres query timed out"}
      {:exit, reason} -> {:error, "postgres connection failed: #{inspect(reason)}"}
    end
  end

  defp query(connection, sql) do
    case Postgrex.start_link(options(connection)) do
      {:ok, pid} ->
        try do
          run_statement(pid, sql, connection.read_only)
          |> format()
        after
          GenServer.stop(pid)
        end

      {:error, reason} ->
        {:error, "could not connect: #{inspect(reason)}"}
    end
  end

  defp options(connection) do
    [
      hostname: connection.host,
      port: connection.port,
      database: connection.database,
      username: connection.user,
      password: connection.password,
      timeout: @timeout_ms,
      connect_timeout: 5_000,
      backoff_type: :stop,
      pool_size: 1
    ]
  end

  defp run_statement(pid, sql, true = _read_only) do
    # Rolling back always leaves nothing behind, even for a statement that
    # would have written.
    case Postgrex.transaction(pid, fn conn ->
           DBConnection.rollback(conn, read_only_query(conn, sql))
         end) do
      {:error, {:ok, _result} = outcome} -> outcome
      {:error, {:error, _reason} = outcome} -> outcome
      other -> other
    end
  end

  defp run_statement(pid, sql, false = _read_only) do
    Postgrex.transaction(pid, fn conn ->
      case Postgrex.query(conn, sql, []) do
        {:ok, result} -> result
        {:error, reason} -> DBConnection.rollback(conn, reason)
      end
    end)
  end

  defp read_only_query(conn, sql) do
    case Postgrex.query(conn, "SET TRANSACTION READ ONLY", []) do
      {:ok, _result} -> Postgrex.query(conn, sql, [])
      {:error, _reason} = error -> error
    end
  end

  defp format({:ok, %Postgrex.Result{} = result}) do
    rows = result.rows || []

    {:ok,
     %{
       command: to_string(result.command),
       columns: result.columns || [],
       rows: rows |> Enum.take(@max_rows) |> Enum.map(&Enum.map(&1, fn value -> cell(value) end)),
       row_count: result.num_rows,
       truncated?: length(rows) > @max_rows
     }}
  end

  defp format({:error, %Postgrex.Error{postgres: %{message: message}}}),
    do: {:error, "postgres: #{message}"}

  defp format({:error, %Postgrex.Error{message: message}}) when is_binary(message),
    do: {:error, "postgres: #{message}"}

  defp format({:error, reason}), do: {:error, "postgres: #{inspect(reason)}"}

  # A value the JSON encoder can handle, or its printed form.
  defp cell(value) when is_binary(value) do
    if String.valid?(value), do: Output.truncate(value), else: inspect(value)
  end

  defp cell(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp cell(value), do: value |> inspect() |> Output.truncate()
end
