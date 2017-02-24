defmodule SentinelCore.Switchboard do
  @moduledoc """
  The Switchboard manages connections to local peers via MQTT subscriber. It handles incoming messages to join the swarm as well as updates to the peers when new nodes are connected. All subscribers send their messages through this GenServer so that remote subscribers can be easily created.
  """
  use GenServer
  require Logger

  alias SentinelRouter.Network

  @doc """
  Start a GenServer with minimal, default configuration.
  """
  def start_link do
    state = %{
      hostname: hostname(),
      networks: %{},
      peer_clients: %{},
      gateway: nil,
      client: nil
    }
    GenServer.start_link(__MODULE__, state)
  end

  @doc """
  Init by connecting to the local broker and creating a subscription for swarm events.
  """
  def init(%{:hostname => hostname} = state) do
    # Always connect to the local broker
    mqttc = connect(hostname, "localhost")
    # Subscribe to swarm control messages
    :emqttc.subscribe(mqttc, "swarm/+", :qos0)

    # If there was a gateway value set in the ENV, send a message to join the swarm
    state = case default_gateway() do
      nil ->
        state
      gw ->
        send self(), :join_to_gateway
        %{state | gateway: gw}
    end
    # Save the local broker client in the state
    state = Map.put(state, :client, mqttc)

    {:ok, state}
  end

  @doc """
  Join this node to the gateway node to "bootstrap" the swarm.
  """
  def handle_info(:join_to_gateway, %{:client   => _client,
                                      :hostname => hostname,
                                      :gateway  => gateway} = state) do
    # Send message to the gateway
    gateway_client = connect(hostname, gateway)
    net_name = default_network()
    :emqttc.publish(gateway_client, "swarm/join/" <> net_name, hostname)

    {:noreply, %{state | peer_clients: [gateway_client]}}
  end

  @doc """
  Connect to all known peers by creating subscribers for myself on their brokers.
  """
  def handle_info({:connect_local_peers, net_name}, %{:client       => _client,
                                                      :hostname     => hostname,
                                                      :networks     => networks,
                                                      :peer_clients => peer_clients} = state) do
    Logger.debug "subscribe to brokers on: #{inspect networks}"

    # Find which peers we don't have clients for
    already_connected = MapSet.new(Map.keys(peer_clients))
    local_peers = MapSet.new(Network.peers(Map.get(networks, net_name)))
    not_connected = MapSet.difference(local_peers, already_connected)

    # Connect to new peers
    clients = for host <- not_connected, do: Map.put(peer_clients, host, connect(hostname, host))
    Logger.debug "clients: #{inspect clients}"

    {:noreply, %{state | peer_clients: clients}}
  end

  def handle_info(:gossip_peers, %{:client        => _client,
                                   :gateway       => gateway,
                                   :networks      => networks,
                                   :peer_clients  => peer_clients} = state) do
    # Gossip peers to everyone I know
    net_name = default_network()
    peers = Network.peers(Map.get(networks, net_name))
    msg = :erlang.term_to_binary({gateway, net_name, peers})
    for {_peer, peer_client} <- peer_clients, do: :emqttc.publish(peer_client, "swarm/update/" <> net_name, msg)

    {:noreply, state}
  end

  def handle_info({:publish, "swarm/join/" <> net_name, peer}, %{:client   => _client,
                                                                 :hostname => _hostname,
                                                                 :networks => networks} = state) do
    Logger.info "joining node #{peer} with #{inspect networks}"
    network = case Map.has_key?(networks, net_name) do
      true -> Map.get(networks, net_name)
      false -> Network.new
    end

    send self(), {:connect_local_peers, net_name}

    {:noreply, %{state | networks: Map.put(networks, net_name, Network.add(network, peer))}}
  end

  @doc """
  Update the overlay mesh.
  """
  def handle_info({:publish, "swarm/update/" <> net_name, msg}, %{:client   => _client,
                                                                  :gateway  => _gateway,
                                                                  :networks => networks} = state) do
    network = Map.get(networks, net_name)

    Logger.info "swarm/update: #{inspect msg}"
    Logger.info "swarm/update: #{inspect network}"
    {new_gateway, new_peers} = :erlang.binary_to_term(msg)
    state = ensure_gateway(state, new_gateway)
    network = case Network.update_peers(network, new_peers) do
      :no_change ->
        network
      {:changed, network} ->
        # NB: No ^pin - reassigned 'network'
        send self(), {:connect_local_peers, net_name}
        send self(), :gossip_peers
        network
    end
    networks = Map.put(networks, net_name, network)
    {:noreply, %{state | networks: networks}}
  end

  def handle_info({:publish, "node/" <> host, msg}, %{:client   => _client,
                                                      :hostname => hostname} = state) when host == hostname do
    Logger.info "msg to me: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:publish, "node/" <> host, msg}, %{:client   => _client,
                                                      :gateway  => gateway,
                                                      :hostname => hostname} = state) when hostname != gateway do
    Logger.info "msg to #{host}: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:publish, topic, msg}, %{:client => _client} = state) do
    Logger.debug "topic: " <> topic
    Logger.debug "msg: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, %{:hostname => _hostname} = state) do
    Logger.info "disconnected: #{inspect client}"
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :connected}, %{:hostname => hostname} = state) do
    topic = "node/" <> hostname
    Logger.debug "subscribing to #{topic} with #{inspect client}"
    :emqttc.subscribe(client, topic, :qos1)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn "unhandled message: #{inspect msg}"
    {:noreply, state}
  end

  defp hostname do
    System.get_env("HOSTNAME")
  end

  defp default_gateway do
    System.get_env("SENTINEL_GATEWAY")
  end

  defp default_network do
    System.get_env("SENTINEL_NETWORK")
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
