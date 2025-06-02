defmodule JidoSignalTest do
  use ExUnit.Case
  doctest JidoSignal

  test "greets the world" do
    assert JidoSignal.hello() == :world
  end
end
