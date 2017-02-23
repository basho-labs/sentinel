defmodule SentinelRouterTest do
  use ExUnit.Case
  use Quixir
  doctest SentinelRouter

  import SentinelRouter.Network

  test "A new %Network{} has 0 peers" do
    assert 0 == num_peers(SentinelRouter.Network.new())
  end
end
