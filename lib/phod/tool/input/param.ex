defmodule Phod.Tool.Input.Param do
  @moduledoc """
  An object to represent a parameter
  """

  @type t :: %__MODULE__{
    type: module(),
    name: atom(),
    desc: String.t(),
    required?: boolean(),
    default: term(),
    opts: map(),
  }

  defstruct type: nil,
    name: nil,
    desc: "",
    required?: false,
    default: nil,
    opts: %{}

  def required(%__MODULE__{} = param) do
    %{param | required?: true}
  end

  def optional(%__MODULE__{} = param, default_val) do
    %{param |
      required?: false,
      default: default_val,
    }
  end

  def to_schema(%__MODULE__{} = param) do
    %{
      type: param.type.schema_type(),
    }
  end
end
