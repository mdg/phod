defmodule Phod.Session.ConnectionsTest do
  use ExUnit.Case, async: true

  alias Phod.Session

  # Starts a session on a fresh worktree under the test base.
  defp start_session do
    tree = "conn-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _pid} = Session.ensure_started("tester", tree)
    Session.session_id("tester", tree)
  end

  setup do
    a = start_session()
    b = start_session()
    on_exit(fn -> Session.disconnect(a, b) end)
    %{a: a, b: b}
  end

  test "a mutual connection (the default) lets each side message the other", %{a: a, b: b} do
    assert :ok = Session.connect(a, b)
    assert Session.peers(a) == [b]
    assert Session.peers(b) == [a]
  end

  test "a one-way connection lets only the first session message the second", %{a: a, b: b} do
    assert :ok = Session.connect(a, b, mode: :one_way)
    assert Session.peers(a) == [b]
    assert Session.peers(b) == []
  end

  test "a session can't connect to itself", %{a: a} do
    assert {:error, :self} = Session.connect(a, a)
  end

  test "connecting the same pair twice is an error", %{a: a, b: b} do
    assert :ok = Session.connect(a, b)
    assert {:error, :already_connected} = Session.connect(a, b)
  end

  test "connecting to a session that isn't running is an error", %{a: a} do
    missing = "tester/no-such-session"
    assert {:error, {:not_found, ^missing}} = Session.connect(a, missing)
  end

  test "an unknown mode is an error", %{a: a, b: b} do
    assert {:error, {:invalid_mode, :sideways}} = Session.connect(a, b, mode: :sideways)
  end

  test "disconnect removes both directions", %{a: a, b: b} do
    :ok = Session.connect(a, b)
    assert :ok = Session.disconnect(a, b)
    assert Session.peers(a) == []
    assert Session.peers(b) == []
  end

  test "disconnecting sessions that aren't connected is an error", %{a: a, b: b} do
    assert {:error, :not_connected} = Session.disconnect(a, b)
  end

  test "the snapshot lists the peers", %{a: a, b: b} do
    assert %{peers: []} = Session.get_snapshot(a)
    :ok = Session.connect(a, b, mode: :one_way)
    assert %{peers: [^b]} = Session.get_snapshot(a)
  end
end
