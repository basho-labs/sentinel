defmodule SentinelCore.Switchboard do
  use GenServer
  require Logger
  
  def start_link do
    state = %{
      hostname: hostname(), 
      peers: MapSet.new, 
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
    Agent.start fn ->
      mqttc = connect(hostname, gateway)
      receive do
        # Once connected, send the message
        {:mqttc, cl, :connected} ->
          :emqttc.publish(cl, "swarm/join", hostname)
          # Disconnect after publishing
          :emqttc.disconnect(mqttc)
        msg ->
          Logger.debug "got #{inspect msg} from join agent"
      end
    end

    {:noreply, state}
  end

  def handle_info(:connect_local_peers, %{:client       => _client, 
                                          :hostname     => hostname,
                                          :peers        => peers,
                                          :peer_clients => peer_clients} = state) do
    Logger.debug "subscribe to brokers on: #{inspect peers}"

    # Disconnect from all clients to clean up
    for {_peer, peer_client} <- peer_clients, do: :emqttc.disconnect(peer_client)
    # Connect to new peers again
    clients = for host <- peers, do: {host, connect(hostname, host)}
    Logger.debug "clients: #{inspect clients}"

    {:noreply, %{state | peer_clients: clients}}
  end

  def handle_info(:gossip_peers, %{:client        => _client,
                                   :gateway       => gateway,
                                   :peers         => peers,
                                   :peer_clients  => peer_clients} = state) do
    # Gossip peers to everyone I know
    msg = :erlang.term_to_binary({gateway, peers})
    for {_peer, peer_client} <- peer_clients, do: :emqttc.publish(peer_client, "swarm/update", msg)

    {:noreply, state}
  end

  def handle_info({:publish, "swarm/join", msg}, %{:client    => _client, 
                                                   :hostname  => _hostname,
                                                   :peers     => peers} = state) do
    Logger.info "joining node #{msg} with #{inspect peers}"
    send self(), :connect_local_peers

    {:noreply, %{state | peers: MapSet.put(peers, msg)}}
  end

  @doc """
  Update the overlay mesh.
  """
  def handle_info({:publish, "swarm/update", msg}, %{:client  => _client,
                                                     :gateway => gateway,
                                                     :peers   => peers} = state) do
    Logger.info "swarm/update: #{inspect msg}"
    Logger.info "swarm/update: #{inspect peers}"
    {new_gateway, new_peers} = :erlang.binary_to_term(msg)
    new_state = Map.put(state, :peers, case update_peers(new_peers, peers) do
      :no_change -> 
        peers
      {:ok, merged_peers} -> 
        send self(), :connect_local_peers
        send self(), :gossip_peers
        merged_peers
    end)
    new_state = case gateway do
      nil -> Map.put(new_state, :gateway, new_gateway)
      _gw -> new_state
    end
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
  
  defp hostname do
    System.get_env("HOSTNAME")
  end

  defp default_gateway do
    System.get_env("SENTINEL_GATEWAY")
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
  
  defp update_peers(new_peers, peers) do
    before_hash = hash_peers(peers)
    merged_peers = MapSet.union(new_peers, peers)
    after_hash = hash_peers(merged_peers)
    Logger.debug "my_mesh hash: " <> Base.encode16(after_hash)
    case before_hash != after_hash do
      false   -> :no_change
      true    -> {:ok, merged_peers}
    end
  end

  defp hash_peers(peers) do
    hash(peers |> MapSet.to_list |> Enum.sort)
  end
  
  def hash(items) do
    hash(items, [])
  end

  def hash([], hash) do
    hash
  end

  def hash([first | rest], hash) do
    hash(rest, :crypto.hash(:sha256, [hash, first]))
  end
  
end
