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
    defstruct peers: []

    def new(peer_hosts \\ []) do
      %Network{peers: peer_hosts}
    end
    
    # TODO: Use a set or something, prevent dupes
    def peers(%Network{peers: prs}) do
      prs
    end

    def num_peers(%Network{peers: prs}) do
      length(prs)
    end
  end
end
