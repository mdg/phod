defmodule Phod.Session.NetworkTest do
  use ExUnit.Case, async: true

  alias Phod.Session.Network

  @http %{"docs" => %{host: "docs.internal", port: 8080}}
  @pg %{
    "analytics" => %{host: "db.internal", port: 5432, database: "app", user: "reader", password: "secret"}
  }

  describe "normalize/1" do
    test "no config is an empty network" do
      assert {:ok, %{http: %{}, postgres: %{}}} = Network.normalize(nil)
      assert {:ok, %{http: %{}, postgres: %{}}} = Network.normalize(%{})
    end

    test "connections are kept by label, and read_only defaults to true" do
      assert {:ok, network} = Network.normalize(%{http: @http, postgres: @pg})

      assert network.http["docs"] == %{host: "docs.internal", port: 8080, read_only: true, label: "docs"}

      assert network.postgres["analytics"].read_only == true
      assert network.postgres["analytics"].password == "secret"
    end

    test "keyword lists and atom labels are accepted" do
      assert {:ok, network} = Network.normalize(http: [docs: [host: "h", port: 1, read_only: false]])
      assert network.http["docs"].read_only == false
    end

    test "a label must be a lowercase identifier" do
      assert {:error, {:invalid_label, :http, "Bad-Label"}} =
               Network.normalize(%{http: %{"Bad-Label" => %{host: "h", port: 1}}})

      assert {:error, {:invalid_label, :http, "1st"}} =
               Network.normalize(%{http: %{"1st" => %{host: "h", port: 1}}})
    end

    test "a connection needs its required fields" do
      assert {:error, {:invalid_connection, :http, "docs", {:missing, [:port]}}} =
               Network.normalize(%{http: %{"docs" => %{host: "h"}}})

      assert {:error, {:invalid_connection, :postgres, "analytics", {:missing, [:password]}}} =
               Network.normalize(%{postgres: %{"analytics" => %{@pg["analytics"] | password: nil} |> Map.delete(:password)}})
    end

    test "field values are checked" do
      assert {:error, {:invalid_connection, :http, "docs", {:bad_field, :port}}} =
               Network.normalize(%{http: %{"docs" => %{host: "h", port: 0}}})

      assert {:error, {:invalid_connection, :http, "docs", {:bad_field, :host}}} =
               Network.normalize(%{http: %{"docs" => %{host: "", port: 80}}})

      assert {:error, {:invalid_connection, :http, "docs", {:bad_field, :read_only}}} =
               Network.normalize(%{http: %{"docs" => %{host: "h", port: 80, read_only: "yes"}}})
    end

    test "unknown fields and protocols are errors" do
      assert {:error, {:invalid_connection, :http, "docs", {:unknown, [:timeout]}}} =
               Network.normalize(%{http: %{"docs" => %{host: "h", port: 80, timeout: 5}}})

      assert {:error, {:unknown_protocols, [:ftp]}} = Network.normalize(%{ftp: %{}})
    end
  end

  test "tools are named by protocol and label, sorted by name" do
    {:ok, network} = Network.normalize(%{http: @http, postgres: @pg})

    assert [
             {"http_docs", Phod.Tool.Http, _},
             {"postgres_analytics", Phod.Tool.Postgres, _}
           ] = Network.tools(network)
  end

  test "each connection's tool description names its endpoint and never shows a password" do
    {:ok, network} = Network.normalize(%{http: @http, postgres: @pg})
    specs = network |> Network.tools() |> Network.specs()

    descriptions = Enum.map(specs, & &1["description"])
    assert Enum.any?(descriptions, &(&1 =~ "docs.internal:8080"))
    assert Enum.any?(descriptions, &(&1 =~ "postgres_analytics"))
    refute Enum.any?(descriptions, &(&1 =~ "secret"))
  end

  test "every network tool requires a goal" do
    {:ok, network} = Network.normalize(%{http: @http, postgres: @pg})

    for spec <- network |> Network.tools() |> Network.specs() do
      assert "goal" in spec["input_schema"]["required"]
    end
  end

  test "labels for a snapshot show no credentials" do
    {:ok, network} = Network.normalize(%{http: @http, postgres: @pg})
    assert Network.labels(network) == %{http: ["docs"], postgres: ["analytics"]}
  end
end
