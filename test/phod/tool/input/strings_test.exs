defmodule Phod.Tool.Input.StringsTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input
  alias Phod.Tool.Input.Strings

  test "name, schema type and item type" do
    assert Strings.name() == :strings
    assert Strings.schema_type() == "array"
    assert Strings.item_type() == "string"
    assert is_binary(Strings.desc())
  end

  test "accepts a non-empty list of non-empty strings, in order" do
    assert {:ok, ["ls", "-l"]} = Strings.validate(["ls", "-l"], %{})
  end

  test "rejects an empty list and a non-list" do
    assert {:error, "invalid empty strings"} = Strings.validate([], %{})
    assert {:error, "invalid strings"} = Strings.validate("ls", %{})
  end

  test "rejects entries that are not strings" do
    assert {:error, "invalid empty string in list"} = Strings.validate(["ls", 1], %{})
  end

  test "the constructor builds a param of this type" do
    param = Input.strings(:cmd, "command", required: true)

    assert param.type == Strings
    assert param.required?
    assert Input.to_schema([param])["properties"]["cmd"] == %{
             "type" => "array",
             "items" => %{"type" => "string"}
           }
  end
end
