defmodule SentinelCore.PeerSupervisor do
  use Supervisor
  require Logger

  import Supervisor.Spec

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def connect(host) do
    Supervisor.start_child(__MODULE__, worker(SentinelCore.Peer, [host], id: String.to_atom(host)))
  end

  def connect_watson(host) do
    Supervisor.start_child(__MODULE__, worker(SentinelCore.WatsonPeer, [host], id: String.to_atom(host)))
  end

  def init([]) do
    children = [
      worker(SentinelCore.Peer, ["localhost"], id: :localhost)
    ]
    supervise(children, strategy: :one_for_one)
  end

end