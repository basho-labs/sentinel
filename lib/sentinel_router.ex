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
    defstruct [:peers]

    @doc """
    Create a new %Network{}, possibly seeded with a list of peers.
    """
    def new(peer_hosts \\ []) do
      %Network{ peers: MapSet.new(peer_hosts) }
    end
    
    @doc """
    Get the (sorted) list of all known peers
    """
    def peers(%Network{peers: prs}) do
      MapSet.to_list(prs) |> Enum.sort
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
      %Network{peers: MapSet.put(prs, peer)}
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
      %Network{peers: MapSet.delete(prs, peer)}
    end
  end
end
