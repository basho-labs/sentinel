defmodule SentinelRouterTest do
  use ExUnit.Case
  use Quixir
  doctest SentinelRouter

  import SentinelRouter.Network

  test "A new %Network{} has 0 peers" do
    assert 0 == num_peers(new())
  end

  test "A new %Network{} can be grown by adding a peer" do
    ptest peer: string() do
      new_network = new()
      assert 0 == num_peers(new_network)
      full_nwk = add(new_network, peer)
      assert 1 == num_peers(full_nwk)
    end
  end

  test "A peer cannot be added twice to the same %Network{}" do
    ptest peer: string() do
      network = new()
      network = add(network, peer)
      network = add(network, peer)
      assert 1 == num_peers(network)
    end
  end
  
end
