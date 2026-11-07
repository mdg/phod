defmodule Phod.Tool.Input.DiffTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input.Diff

  test "name and schema type" do
    assert Diff.name() == :diff
    assert Diff.schema_type() == "string"
    assert is_binary(Diff.desc())
  end

  test "accepts a non-empty diff and trims it" do
    assert {:ok, "--- a\n+++ b"} = Diff.validate("\n--- a\n+++ b\n", %{})
  end

  test "rejects an empty or whitespace-only diff" do
    assert {:error, "cannot apply empty diff"} = Diff.validate("", %{})
    assert {:error, "cannot apply empty diff"} = Diff.validate(" \n\t", %{})
  end

  test "rejects a non-binary diff" do
    assert {:error, "invalid diff"} = Diff.validate(nil, %{})
    assert {:error, "invalid diff"} = Diff.validate(42, %{})
  end
end
