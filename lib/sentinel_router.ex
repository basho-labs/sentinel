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
    defstruct :peers

    def new(peer_hosts \\ []) do
      %Network{ peers: MapSet.new(peer_hosts) }
    end
    
    # TODO: Use a set or something, prevent dupes
    def peers(%Network{peers: prs}) do
      MapSet.to_list(prs)
    end

    def num_peers(%Network{peers: prs}) do
      MapSet.size(prs)
    end

    @doc """
    Add a new peer to our known peers.
    """
    def add(%Network{peers: prs}, peer) do
      %Network{peers: MapSet.put(prs, peer)}
    end
  end
end
