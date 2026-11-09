defmodule Phod.Tool.Output do
  @moduledoc """
  Caps the size of text a tool returns to the model, so one large result can't
  fill the context.
  """

  @max_output_bytes 20_000

  @doc """
  Returns `text` unchanged if it fits in #{@max_output_bytes} bytes. Otherwise
  it's cut at that size, back to a valid UTF-8 boundary, with a note saying so.
  """
  @spec truncate(binary()) :: binary()
  def truncate(text) when byte_size(text) <= @max_output_bytes, do: text

  def truncate(text) do
    text
    |> binary_part(0, @max_output_bytes)
    |> valid_utf8_prefix()
    |> Kernel.<>("\n... (truncated: output exceeds #{@max_output_bytes} bytes)")
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
