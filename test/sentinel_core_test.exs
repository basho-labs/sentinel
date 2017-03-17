defmodule SentinelCoreTest do
  use ExUnit.Case
  use Quixir
  doctest SentinelCore

  alias SentinelRouter.Network

  test "the truth" do
    assert 1 + 1 == 2
  end

  # Custom generators are just functions made of other generator functions
  def mystring(args) do
    string(args)
  end

  def peername() do
    string(min: 1, max: 32, chars: :lower)
  end

  def netname() do
    string(min: 1, max: 32, chars: :lower)
  end

  def peers() do
    list(min: 1, of: peername())
  end

  def network() do
    tuple(like: { netname(), list(min: 1, of: peername()) })
  end

  # networks = %{}
  #

  def networks() do
    list(of: network(), min: 1)
  end

  test "SentinelCore tests can use network() generator appropriately" do
    ptest network: network() do
      # TODO: Would be nice to work the deconstruction into the generator
      {name, peers} = network
      assert name != ""
      assert peers != []
    end
  end

  test "networks generator can be used to build state.networks" do
    ptest network_metadata: networks() do
      # This is really still the constructor/generator, until I figure out
      # how to generate the %Network{} structs directly
      nets = Enum.reduce(network_metadata,
                         %{},
                         fn({name, peers}, ns) ->
                           Map.put(ns, name, Network.new(peers))
                         end)

      {:ok, is_gw} = SentinelCore.is_gateway(nets)
      multiple_nets = length(network_metadata) > 1
      assert (is_gw and multiple_nets) or (!is_gw and !multiple_nets)
    end
  end

  test "SentinelCore.add_to_network/3 works from %{}" do
    ptest net: netname(), peer: peername() do
      nets = %{}
      {:ok, nets} = SentinelCore.add_to_network(nets, net, peer)
      assert 1 == map_size(nets)
      %{ ^net => n } = nets
      # add_to_network/3 auto-adds `hostname` to the network
      assert Enum.sort([ peer , SentinelCore.hostname() ]) == Enum.sort(Network.peers(n))
    end
  end

  test "SentinelCore.send_msg_all/2 skips own hostname" do
    ptest locals: peers(), remotes: peers() do
      me = SentinelCore.hostname()
      assert {:ok, :me} == SentinelCore.node_locality(me, locals)
      assert {:ok, :local} == SentinelCore.node_locality(hd(locals), locals)
      assert {:ok, :nonlocal} == SentinelCore.node_locality(hd(remotes), locals)
    end
  end

end
