defmodule Phod.Tool.Input.StringTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input.String, as: StringType

  test "name and schema type" do
    assert StringType.name() == :string
    assert StringType.schema_type() == "string"
    assert is_binary(StringType.desc())
  end

  test "accepts a non-blank string unchanged" do
    assert {:ok, "IO.puts(\"hi\")\n"} = StringType.validate("IO.puts(\"hi\")\n", %{})
  end

  test "rejects an empty or whitespace-only string" do
    assert {:error, "invalid empty string"} = StringType.validate("", %{})
    assert {:error, "invalid empty string"} = StringType.validate(" \n\t", %{})
  end

  test "rejects non-string values" do
    for value <- [nil, 1, :atom, ["a"], %{}] do
      assert {:error, msg} = StringType.validate(value, %{})
      assert msg =~ "invalid string"
    end
  end
end
