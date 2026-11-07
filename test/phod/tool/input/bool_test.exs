defmodule Phod.Tool.Input.BoolTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input.Bool

  test "name and schema type" do
    assert Bool.name() == :bool
    assert Bool.schema_type() == "boolean"
    assert is_binary(Bool.desc())
  end

  test "accepts true and false" do
    assert {:ok, true} = Bool.validate(true, %{})
    assert {:ok, false} = Bool.validate(false, %{})
  end

  test "ignores session opts" do
    assert {:ok, true} = Bool.validate(true, %{session_root: "/nonexistent"})
  end

  test "rejects non-boolean values" do
    for value <- ["true", "false", 1, 0, nil, %{}, []] do
      assert {:error, msg} = Bool.validate(value, %{})
      assert msg =~ "invalid boolean"
    end
  end
end
