defmodule SentinelCore.Switchboard do
  @moduledoc """
  The Switchboard manages connections to local peers via MQTT subscriber. It handles incoming messages to join the swarm as well as updates to the peers when new nodes are connected. All subscribers send their messages through this GenServer so that remote subscribers can be easily created.
  """
  use GenServer
  require Logger

  alias SentinelCore.PeerSupervisor
  alias SentinelRouter.Network

  @doc """
  Start a GenServer with minimal, default configuration.
  """
  def start_link do
    state = %{
      networks: %{},
      gateway: nil
    }
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @doc """
  Init by connecting to the local broker and creating a subscription for swarm events.
  """
  def init(state) do
    # If there was a gateway value set in the ENV, send a message to join the swarm
    state = case SentinelCore.default_gateway() do
      nil ->
        if System.get_env("ORG_ID") != nil do
          send self(), :connect_to_watson
        end
        state
      gw ->
        send self(), :join_default_swarm
        %{state | gateway: String.to_atom(gw)}
    end
    Logger.debug "[switchboard] starting with state: #{inspect state}"
    {:ok, state}
  end

  @doc """
  Create a client for Watson IoT and connect.
  """
  def handle_info(:connect_to_watson, state) do

    # Get Watson Creds
    %{
      :org_id => org_id, 
      :device_type => device_type, 
      :device_id => device_id, 
      :auth_token => auth_token
    } = watson_opts = watson_opts()

    client_id = "g:" <> org_id <> ":" <> device_type <> ":" <> device_id
    host = org_id <> ".messaging.internetofthings.ibmcloud.com"
    port = "1883"
    username = "use-token-auth"
    password = auth_token
    
    watson_client = connect_watson(client_id, [host, port, username, password])

    new_opts = %{
      client_id: client_id,
      watson_host: host,
      watson_port: port,
      watson_username: username,
      watson_password: password,
      watson: watson_client
    }

    {:noreply, Map.put(state, :watson_opts, Map.merge(watson_opts, new_opts))}
  end

  @doc """
  Join this node to the gateway node to "bootstrap" the swarm.
  """
  def handle_info(:join_default_swarm, state) do
    default_network = SentinelCore.default_network()
    # Send message to the gateway
    handle_join(default_network, state)
  end

  @doc """
  Connect to all known peers by creating subscribers for myself on their brokers.
  """
  def handle_info({:connect_local_peers, overlay}, %{:networks => networks} = state) do
    network = Map.get(networks, overlay)
    local_peers = Network.peers(network)

    # Find which peers we don't have clients for
    not_connected = Enum.filter(local_peers, fn p -> Process.whereis(String.to_atom(p)) == nil end)
    Logger.debug "[switchboard] not connected: #{inspect not_connected}"
    for p <- local_peers, do: PeerSupervisor.connect(p)

    {:noreply, state}
  end

  @doc """
  Send the list of peers around to other nodes I know about to converge the cluster view.
  """
  def handle_info({:gossip_peers, overlay}, %{:networks => networks} = state) do
    # Gossip peers to everyone I know
    network = Map.get(networks, overlay)
    local_peers = Network.peers(network)

    pubopts = [{:retain, true}]
    for p <- local_peers, do: send String.to_atom(p), {:send, "swarm/update/" <> overlay, local_peers, pubopts}

    {:noreply, state}
  end

  @doc """
  Handle a message not intended for me. 
  
  TODO: Whether the message is really handled or not depends on whether I'm a replica for this node.
  """
  def handle_info({:publish, "node/" <> host = _topic, msg}, %{:gateway => gateway} = state) when nil != gateway do
    state = case Process.whereis(String.to_atom(host)) do
      nil ->
        # Non-local node. Forward to gateway.
        handle_forward({:nonlocal, host, msg}, state)
      _pid ->
        # Local node. Send to local broker.
        handle_forward({:local, host, msg}, state)
    end
    {:noreply, state}
  end

  @doc """
  Dispatch all Published messages on all topics to handler.
  Split the topic on "/" for easier matching.
  """
  def handle_info({:publish, topic, message}, state) do
    handle_publish(String.split(topic, "/"), message, state)
  end

  def handle_info(msg, state) do
    Logger.warn "[switchboard] unhandled message: #{inspect msg}"
    {:noreply, state}
  end

  def handle_join(overlay, %{:gateway => gateway} = state) when nil != gateway do
    myself = SentinelCore.hostname()
    # Send a join message to the gateway for the network to which I belong.
    PeerSupervisor.connect(to_string(gateway))
    send gateway, {:send, "swarm/join/" <> overlay, myself}
    {:noreply, state}
  end

  @doc """
  Join the node to the named network and immediately try and connect to it.
  """
  def handle_publish(["swarm", "join", overlay], {_from, peer}, %{:networks => networks} = state) do
    Logger.debug "[switchboard] joining node #{inspect peer} with #{inspect networks}"
    networks = Map.update(networks, overlay, Network.new([peer]), fn n ->
      Network.add(n, peer)
    end)
    Logger.debug "[switchboard] networks: #{inspect networks}"

    for event <- [:connect_local_peers, :gossip_peers], do: send self(), {event, overlay}

    {:noreply, %{state | networks: networks}}
  end

  @doc """
  Update the overlay mesh.
  """
  def handle_publish(["swarm", "update", overlay], {_from, overlay_peers}, %{:networks => networks} = state) do
    network = case Map.get(networks, overlay) do
      nil -> Network.new
      n -> n
    end
    Logger.debug "[switchboard] swarm/update: #{inspect overlay_peers} #{inspect network}"

    network = case Network.update_peers(network, overlay_peers) do
      :no_change ->
        Logger.debug "[switchboard] no change: #{inspect overlay_peers} vs #{Network.peers(network)}"
        network
      {:changed, network} ->
        Logger.debug "[switchboard] changed: #{inspect network}"
        # NB: No ^pin - reassigned 'network'
        for event <- [:connect_local_peers, :gossip_peers], do: send self(), {event, overlay}
        network
    end

    {:noreply, %{state | networks: Map.put(networks, overlay, network)}}
  end

  @doc """
  Handle a message addressed to me.
  """
  def handle_publish(["node", host], msg, %{:name => name} = state) do
    case to_string(name) do
      ^host -> 
        Logger.info "[switchboard] msg to me: #{inspect msg}"
      other_host ->
        Logger.warn "[switchboard] msg NOT to me: #{other_host} #{inspect msg}"
    end
    {:noreply, state}
  end

  def handle_publish(_topic, _message, state) do
    {:noreply, state}
  end

  def handle_forward({:nonlocal, host, msg}, %{:gateway => gateway} = state) do
    Logger.debug "non-local forward for #{host}. Sending to #{inspect gateway}."
    send gateway, {:send, "node/" <> host, msg}
    {:noreply, state}
  end

  def handle_forward({:local, host, msg}, state) do
    Logger.debug "local forward for #{host}. Sending to localhost."
    send :localhost, {:send, "node/" <> host, msg}
    {:noreply, state}
  end

  defp watson_opts do
    org_id = System.get_env("ORG_ID")
    device_type = System.get_env("DEVICE_TYPE")
    device_id = System.get_env("DEVICE_ID")
    auth_token = System.get_env("AUTH_TOKEN")
    watson_opts = %{org_id: org_id, device_type: device_type, device_id: device_id, auth_token: auth_token}
    watson_opts
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
