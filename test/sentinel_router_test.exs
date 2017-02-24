defmodule SentinelRouterTest do
  use ExUnit.Case
  use Quixir
  doctest SentinelRouter

  import SentinelRouter.Network

  test "A new %Network{} has 0 peers" do
    assert 0 == size(new())
  end

  test "A new %Network{} can be grown by adding a peer" do
    ptest peer: string() do
      new_network = new()
      assert 0 == size(new_network)
      full_nwk = add(new_network, peer)
      assert 1 == size(full_nwk)
    end
  end

  test "A peer cannot be added twice to the same %Network{}" do
    ptest peer: string() do
      network = new()
      network = add(network, peer)
      network = add(network, peer)
      assert 1 == size(network)
    end
  end

  test "Can remove a peer from the %Network{}" do
    ptest peer: string() do
      network = new()
      network = add(network, peer)
      assert 1 == size(network)
      network = remove(network, peer)
      assert 0 == size(network)
    end
  end

  test "Can add multiple peers to the %Network{}" do
    ptest peers: list(of: string(), min: 1) do
      # Remove duplicate peers (easier than trying to write a generator
      # that never generates duplicates)
      peers = Enum.uniq(peers)
      network = new(peers)
      assert length(peers) == size(network)
      [p0 |_] = peers
      network = remove(network, p0)
      assert length(peers) - 1 == size(network)
    end
  end

  test "We can detect a peer once added to the %Network{}" do
    ptest peers: list(of: string(), min: 1) do
      peers = Enum.uniq(peers)
      network = new()
      assert false == peer?(network, hd(peers))
      network = new(peers)
      assert true == peer?(network, hd(peers))
      network = remove(network, hd(peers))
      assert false == peer?(network, hd(peers))
    end
  end

  test "updating with a known peer tells us :no_change" do
    ptest peer: string() do
      network = new([peer])
      assert :no_change = update_peers(network, [peer])
    end
  end

  test "updating with a new peer tells us :changed"  do
    ptest peer: string() do
      network = new()
      assert {:changed, newnetwk} = update_peers(network, [peer])
      assert 1 == size(newnetwk)
      assert :no_change = update_peers(newnetwk, [peer])
    end
  end

end
