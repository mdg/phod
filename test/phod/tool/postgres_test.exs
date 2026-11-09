defmodule Phod.Tool.PostgresTest do
  # Runs against the test database the Repo already uses.
  use ExUnit.Case, async: true

  alias Phod.Tool.Postgres

  defp conn(overrides \\ %{}) do
    Map.merge(
      %{
        host: "localhost",
        port: 5433,
        database: "phod_test",
        user: "phodapi",
        password: "phod123",
        label: "analytics",
        read_only: true
      },
      overrides
    )
  end

  defp run(sql, connection \\ conn()) do
    Postgres.run(%{sql: sql}, %{connection: connection})
  end

  test "a select returns its columns and rows" do
    assert {:ok, %{command: "select", columns: ["x", "y"], rows: [[1, "a"]], row_count: 1, truncated?: false}} =
             run("SELECT 1 AS x, 'a' AS y")
  end

  test "a read-only connection refuses writes, whatever the SQL" do
    assert {:error, "postgres: cannot execute CREATE TABLE in a read-only transaction"} =
             run("CREATE TEMP TABLE scratch (x int)")
  end

  test "a connection that isn't read-only can write" do
    assert {:ok, %{command: "create_table"}} =
             run("CREATE TEMP TABLE scratch (x int)", conn(%{read_only: false}))
  end

  test "a read-only statement leaves nothing behind" do
    assert {:error, _} = run("CREATE TEMP TABLE leftover (x int)")
    assert {:error, _} = run("SELECT * FROM leftover")
  end

  test "a syntax error is returned as the database's message" do
    assert {:error, "postgres: " <> message} = run("SELEC 1")
    assert message =~ "syntax error"
  end

  test "rows are capped, and the result says so" do
    assert {:ok, %{rows: rows, row_count: 150, truncated?: true}} =
             run("SELECT g FROM generate_series(1, 150) AS g")

    assert length(rows) == 100
  end

  test "a wrong password is an error, not a crash" do
    assert {:error, _reason} = run("SELECT 1", conn(%{password: "wrong"}))
  end
end
