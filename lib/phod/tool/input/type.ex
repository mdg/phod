defmodule Phod.Tool.Input.Type do
  @moduledoc """
  A behavior to describe input types, their purpose and validation logic
  """

  @callback name() :: atom()
  @callback desc() :: String.t()
  @callback validate(term(), map()) :: Rexult.t()
  @callback schema_type() :: String.t()
end
