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
    :emqttc.subscribe(mqttc, "swarm/#", :qos0)
    :emqttc.subscribe(mqttc, "node/#", :qos1)

    # If there was a gateway value set in the ENV, send a message to join the swarm
    state = case default_gateway() do
      nil ->
        send self(), :connect_to_watson
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
  Create a client for Watson IoT and connect.
  """
  def handle_info(:connect_to_watson, state) do

    # Get Watson Creds
    org_id = watson_org_id()
    Map.put(state, :org_id, org_id)

    device_type = watson_device_type()
    Map.put(state, :device_type, device_type)

    device_id = watson_device_id()
    Map.put(state, :device_id, device_id)

    auth_token = watson_auth_token()
    Map.put(state, :auth_token, auth_token)

    client_id = "g:" <> org_id <> ":" <> device_type <> ":" <> device_id
    Map.put(state, :client_id, client_id)

    host = org_id <> ".messaging.internetofthings.ibmcloud.com"
    Map.put(state, :watson_host, host)

    port = "1883"
    Map.put(state, :watson_port, port)

    username = "use-token-auth"
    Map.put(state, :watson_username, username)

    password = auth_token
    Map.put(state, :watson_password, password)

    watson_client = connect_watson(client_id, [host, port, username, password])
    Map.put(state, :watson, watson_client)

    {:noreply, state}
  end

  @doc """
  Join this node to the gateway node to "bootstrap" the swarm.
  """
  def handle_info(:join_to_gateway, %{:hostname     => hostname,
                                      :gateway      => gateway,
                                      :peer_clients => peer_clients} = state) do
    # Send message to the gateway
    gateway_client = connect(hostname, gateway)
    net_name = default_network()
    :emqttc.publish(gateway_client, "swarm/join/" <> net_name, hostname)

    {:noreply, %{state | peer_clients: Map.put(peer_clients, gateway, gateway_client)}}
  end

  @doc """
  Connect to all known peers by creating subscribers for myself on their brokers.
  """
  def handle_info({:connect_local_peers, net_name}, %{:hostname     => hostname,
                                                      :networks     => networks,
                                                      :peer_clients => peer_clients} = state) do
    Logger.info "subscribe to brokers on: #{inspect networks}"

    # Find which peers we don't have clients for
    already_connected = MapSet.new(Map.keys(peer_clients))
    Logger.debug "already connected: #{inspect already_connected}"
    local_peers = MapSet.new(Network.peers(Map.get(networks, net_name)))
    not_connected = MapSet.difference(local_peers, already_connected)
    Logger.debug "not connected: #{inspect not_connected}"

    # Connect to new peers
    clients = for host <- not_connected, do: {host, connect(hostname, host)}
    Logger.debug "clients: #{inspect clients}"

    {:noreply, %{state | peer_clients: Map.merge(peer_clients, Map.new(clients))}}
  end

  @doc """
  Send the list of peers around to other nodes I know about to converge the cluster view.
  """
  def handle_info({:gossip_peers, net_name}, %{:gateway      => gateway,
                                               :networks     => networks,
                                               :peer_clients => peer_clients} = state) do
    # Gossip peers to everyone I know
    peers = Network.peers(Map.get(networks, net_name))
    msg = :erlang.term_to_binary({gateway, peers})
    for {_peer, cl} <- peer_clients, do: :emqttc.publish(cl, "swarm/update/" <> net_name, msg)

    {:noreply, state}
  end

  @doc """
  Join the node to the named network and immediately try and connect to it.
  """
  def handle_info({:publish, "swarm/join/" <> net_name, peer}, %{:networks => networks} = state) do
    Logger.debug "joining node #{peer} with #{inspect networks}"
    networks = Map.update(networks, net_name, Network.new([peer]), fn n ->
      Network.add(n, peer)
    end)
    Logger.debug "networks: #{inspect networks}"

    send self(), {:connect_local_peers, net_name}
    send self(), {:gossip_peers, net_name}

    {:noreply, %{state | networks: networks}}
  end

  @doc """
  Update the overlay mesh.
  """
  def handle_info({:publish, "swarm/update/" <> net_name, msg}, %{:networks => networks} = state) do
    {new_gateway, new_peers} = :erlang.binary_to_term(msg)
    state = ensure_gateway(state, new_gateway)

    networks = Map.update(networks, net_name, Network.new, fn n ->
      Logger.info "swarm/update: #{inspect msg}"
      Logger.info "swarm/update: #{inspect n}"
      case Network.update_peers(n, new_peers) do
        :no_change ->
          Logger.debug "no change: #{inspect new_peers} vs #{Network.peers(n)}"
          n
        {:changed, network} ->
          Logger.debug "changed: #{network}"
          # NB: No ^pin - reassigned 'network'
          send self(), {:connect_local_peers, net_name}
          send self(), {:gossip_peers, net_name}
          network
      end
    end)
    
    {:noreply, %{state | networks: networks}}
  end

  @doc """
  Handle a message addressed to me.
  """
  def handle_info({:publish, "node/" <> host, msg}, %{:hostname => hostname} = state) when host == hostname do
    Logger.info "msg to me: #{inspect msg}"
    {:noreply, state}
  end

  @doc """
  Handle a message not intended for me. 
  
  TODO: Whether the message is really handled or not depends on whether I'm a replica for this node.
  """
  def handle_info({:publish, "node/" <> host = topic, msg}, %{:gateway      => gateway,
                                                              :peer_clients => peer_clients} = state) when nil != gateway do
    case Map.has_key?(peer_clients, host) do
      true ->
        # TODO: Decide whether to handle as a replica
        :pass
      false ->
        Logger.info "forwarding message for #{host} to gateway #{gateway}"
        client = Map.get(peer_clients, gateway)
        :emqttc.publish(client, topic, msg)
    end

    {:noreply, state}
  end

  def handle_info({:publish, topic, msg}, state) do
    Logger.info "topic: " <> topic
    Logger.info "msg: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, state) do
    Logger.info "disconnected: #{inspect client}"
    {:noreply, state}
  end

  @doc """
  Subscribe to our `node/$HOSTNAME` topic on the broker we just connected to.
  """
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

  defp watson_org_id do
    System.get_env("ORG_ID")
  end

  defp watson_device_type do
    System.get_env("DEVICE_TYPE")
  end

  defp watson_device_id do
    System.get_env("DEVICE_ID")
  end

  defp watson_auth_token do
    System.get_env("AUTH_TOKEN")
  end

  defp connect_watson(client_id, [host, port, username, password]) do
    {:ok, watson_client} = :emqttc.start_link([
      {:host, String.to_charlist(host)},
      {:port, String.to_integer(port)},
      {:client_id, client_id},
      {:username, username},
      {:password, password},
      {:reconnect, {1, 120}},
      {:keepalive, 0},
      :auto_resub
    ])
    Process.monitor watson_client

    Logger.debug "connected to: #{inspect watson_client}"
    watson_client
  end

end
