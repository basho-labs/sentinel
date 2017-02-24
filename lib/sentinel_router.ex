defmodule SentinelRouter do
  @moduledoc """
  Representation and semantics of, and operations upon, the network topology
  as understood by this node.
  """

  defmodule Network do
    @moduledoc """
    The structure of the network, and operations upon it.
    """
    @doc """
    peers: a list of hostnames of machines in our immediate vicinity.
    """
    defstruct [:peers, :hash]

    @doc """
    Create a new %Network{}, possibly seeded with a list of peers.
    """
    def new(peer_hosts \\ []) do
      peers = MapSet.new(peer_hosts)
      %Network{
        peers: peers,
        hash: hash_peers(peers)
      }
    end

    @doc """
    Get the (sorted) list of all known peers
    """
    def peers(%Network{peers: prs}) do
      MapSet.to_list(prs) |> Enum.sort
    end

    @doc """
    Get the current hash of the network peers
    """
    def hash(%Network{hash: hash}) do
      hash
    end

    @doc """
    Get the size of our known network.
    TODO I feel like there's a protocol we should use here, to make our %Network{}
    size-able - maybe Enumerable? It probably just delegates to %MapSet{} for now?
    """
    def size(%Network{peers: prs}) do
      MapSet.size(prs)
    end

    @doc """
    Add a new peer to our known peers.
    """
    def add(%Network{peers: prs}, peer) do
      new_peers = MapSet.put(prs, peer)
      %Network{peers: new_peers, hash: hash_peers(new_peers)}
    end

    @doc """
    Test if a given peer exists in the known network.
    """
    def peer?(%Network{peers: prs}, peer) do
      MapSet.member?(prs, peer)
    end

    @doc """
    Forget a peer.
    """
    def remove(%Network{peers: prs}, peer) do
      peers = MapSet.delete(prs, peer)
      %Network{peers: peers, hash: hash_peers(peers)}
    end

    @doc """
    Maybe merge some more peers into our list of known peers.
    Returns an indication of whether anything changed.
    """
    def update_peers(%Network{peers: prs, hash: before_hash}=network, new_peers) do
      merged_peers = MapSet.union(prs, MapSet.new(new_peers))
      after_hash = hash_peers(merged_peers)
      case after_hash do
        ^before_hash ->
          :no_change
        _ ->
          {:changed, %Network{peers: merged_peers, hash: after_hash}}
      end
    end

    defp hash_peers(peers) do
      do_hash(peers |> MapSet.to_list |> Enum.sort)
    end

    defp do_hash(items) do
      do_hash(items, [])
    end

    defp do_hash([], hash) do
      hash
    end

    defp do_hash([first | rest], hash) do
      do_hash(rest, :crypto.hash(:sha256, [hash, first]))
    end

  end

  defimpl Inspect, for: Network do
    import Inspect.Algebra

    def inspect(%Network{peers: dict}, opts) do
      concat ["#Network<", to_doc(MapSet.to_list(dict), opts), ">"]
    end
  end
end
