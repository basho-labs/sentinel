defmodule SentinelCore.Switchboard do
  use GenServer
  require Logger

  alias SentinelRouter.Network
  
  def start_link do
    state = %{
      hostname: hostname(), 
      network: Network.new(),
      peer_clients: [],
      gateway: nil,
      client: nil
    }
    GenServer.start_link(__MODULE__, state)
  end
  
  def init(%{:hostname => hostname} = state) do
    # Always connect to the local broker
    mqttc = connect(hostname, "localhost")
    # Subscribe to swarm control messages
    :emqttc.subscribe(mqttc, "swarm/+", :qos0)

    # If there was a gateway value set in the ENV, send a message to join the swarm
    new_state = case default_gateway() do
      nil -> 
        state
      gw -> 
        send self(), :join_to_gateway
        %{state | gateway: gw}
    end
    # Save the local broker client in the state
    new_state = Map.put(new_state, :client, mqttc)
  
    {:ok, new_state}
  end

  def handle_info(:join_to_gateway, %{:client   => _client,
                                      :hostname => hostname,
                                      :gateway  => gateway} = state) do
    # Send message to the gateway
    gateway_client = connect(hostname, gateway)
    :emqttc.publish(gateway_client, "swarm/join", hostname)

    {:noreply, %{state | peer_clients: [gateway_client]}}
  end

  def handle_info(:connect_local_peers, %{:client       => _client, 
                                          :hostname     => hostname,
                                          :network      => network,
                                          :peer_clients => peer_clients} = state) do
    Logger.debug "subscribe to brokers on: #{inspect network}"

    # Disconnect from all clients to clean up
    for {_peer, peer_client} <- peer_clients, do: :emqttc.disconnect(peer_client)
    # Connect to new peers again
    clients = for host <- Network.peers(network), do: {host, connect(hostname, host)}
    Logger.debug "clients: #{inspect clients}"

    {:noreply, %{state | peer_clients: clients}}
  end

  def handle_info(:gossip_peers, %{:client        => _client,
                                   :gateway       => gateway,
                                   :network       => network,
                                   :peer_clients  => peer_clients} = state) do
    # Gossip peers to everyone I know
    msg = :erlang.term_to_binary({gateway, Network.peers(network)})
    for {_peer, peer_client} <- peer_clients, do: :emqttc.publish(peer_client, "swarm/update", msg)

    {:noreply, state}
  end

  def handle_info({:publish, "swarm/join", peer}, %{:client    => _client, 
                                                   :hostname  => _hostname,
                                                   :network   => network} = state) do
    Logger.info "joining node #{peer} with #{inspect network}"
    send self(), :connect_local_peers

    {:noreply, %{state | network: Network.add(network, peer)}}
  end

  @doc """
  Update the overlay mesh.
  """
  def handle_info({:publish, "swarm/update", msg}, %{:client  => _client,
                                                     :gateway => gateway,
                                                     :network => network} = state) do
    Logger.info "swarm/update: #{inspect msg}"
    Logger.info "swarm/update: #{inspect network}"
    {new_gateway, new_peers} = :erlang.binary_to_term(msg)
    new_state = ensure_gateway(state, new_gateway)
	network = case Network.update_peers(network, new_peers) do
		  :no_change -> 
			network
		  {:changed, network} -> 
		  # NB: No ^pin - reassigned 'network'
			send self(), :connect_local_peers
			send self(), :gossip_peers
			network
		end
    new_state = Map.put(new_state, :network, network)
    Logger.debug "my_mesh hash: " <> Base.encode16(Network.hash(network))
    {:noreply, new_state}
  end

  def handle_info({:publish, "node/" <> host, msg}, %{:client   => _client, 
                                                      :hostname => hostname} = state) when host == hostname do
    Logger.info "msg to me: #{inspect msg}"
    {:noreply, state}
  end
  
  def handle_info({:publish, topic, msg}, %{:client => _client} = state) do
    Logger.info "topic: " <> topic
    Logger.info "msg: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, %{:hostname => _hostname} = state) do
    Logger.info "disconnected: #{inspect client}"
    {:noreply, state}
  end  

  def handle_info({:mqttc, client, :connected}, %{:hostname => hostname} = state) do
    topic = "node/" <> hostname
    Logger.info "subscribing to #{topic} with #{inspect client}"
    :emqttc.subscribe(client, topic, :qos1)
    {:noreply, state}
  end  

  def handle_info(msg, state) do
    Logger.warn "unexpected message: #{inspect msg}"
    {:noreply, state}
  end  
  
  defp hostname do
    System.get_env("HOSTNAME")
  end

  defp default_gateway do
    System.get_env("SENTINEL_GATEWAY")
  end

  defp ensure_gateway(%{:gateway => nil} = state, gway) do
    %{state | gateway: gway}
  end
  defp ensure_gateway(%{:gateway => _} = state, _) do
    state
  end

  defp connect(myself, host) do
    do_connect(myself, String.split(host, ":"))
  end

  defp do_connect(myself, [host]) do
    do_connect(myself, [host, "1883"])
  end

  defp do_connect(myself, [host, port]) do
    {:ok, remote_client} = :emqttc.start_link([
      {:host, String.to_charlist(host)}, 
      {:port, String.to_integer(port)}, 
      {:client_id, myself},
      {:reconnect, {1, 120}},
      {:keepalive, 0},
      :auto_resub
    ])
    Process.monitor remote_client

    Logger.debug "connected to: #{inspect remote_client}"
    remote_client
  end
end
