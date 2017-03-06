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
      # Populate our view of the local peers by first adding ourself
      # TODO This results in `:nil` in gateways because we don't set the SENTINEL_DEFAULT_NETWORK env var
      state = Kernel.update_in(state[:networks][SentinelCore.default_network()], fn _ -> Network.new([SentinelCore.hostname()]) end)
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
    :emqttc.subscribe(watson_client, "iot-2/type/"<> device_type <> "/id/" <> device_id <> "/cmd/+/fmt/+", :qos1)
    new_opts = %{
      client_id: client_id,
      watson_host: host,
      watson_port: port,
      watson_username: username,
      watson_password: password,
      watson_client: watson_client
    }
    Logger.debug "watson_opt: #{inspect watson_opts}"
    Logger.debug "starting watson pinger"
    after_time = 5000
    Logger.debug "pinging watson every #{inspect after_time} milliseconds"
    Process.send_after(self(), {:ping_watson, after_time}, after_time)
    state = Kernel.update_in(state[:networks]["watson"], fn _ -> Network.new() end)
    state = Map.put(state, :watson_opts, Map.merge(watson_opts, new_opts))
    {:noreply, state}
  end

  def handle_info({:ping_watson, after_time}, %{:networks => networks, :watson_opts => watson_opts} = state) do
    case Map.get(networks, "watson") do
        nil ->
          Logger.info "pinging watson"
          %{:watson_client => watson_client, :device_type => device_type, :device_id => device_id} = watson_opts
          topic = "iot-2/type/"<> device_type <>"/id/"<> device_id <>"/evt/ping/fmt/txt"
          msg = device_id
          :emqttc.publish(watson_client, topic, msg)
          Process.send_after(self(), {:ping_watson, after_time}, after_time)
        _ ->
          :ok
    end
    {:noreply, state}
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
    myself = SentinelCore.hostname()

    # Find which peers we don't have clients for
    not_connected = Enum.filter(local_peers, fn p -> 
      p != myself and Process.whereis(String.to_atom(p)) == nil 
    end)
    Logger.debug "[switchboard] not connected: #{inspect not_connected}"
    for p <- not_connected, do: PeerSupervisor.connect(p)

    {:noreply, state}
  end

  @doc """
  Send the list of peers around to other nodes I know about to converge the cluster view.
  """
  def handle_info({:gossip_peers, overlay}, %{:networks => networks} = state) do
    # Gossip peers to everyone I know
    network = Map.get(networks, overlay)
    local_peers = Network.peers(network)
    myself = SentinelCore.hostname()

    pubopts = [{:qos, 1}, {:retain, true}]
    for p <- local_peers, p != myself, do: send String.to_atom(p), {:send, "swarm/update/" <> overlay, local_peers, pubopts}

    {:noreply, state}
  end

  @doc """
  Dispatch all Published messages on all topics to handler.
  Split the topic on "/" for easier matching.
  """
  def handle_info({:publish, topic, message}, state) do
    handle_publish(String.split(topic, "/"), message, state)
  end

  def handle_info({:mqttc, client, msg}, state) do
    Logger.warn "[switchboard] mqttc message from #{inspect client}: #{inspect msg}"
    {:noreply, state}
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
    Logger.debug "[switchboard] swarm/update/#{inspect overlay}: #{inspect overlay_peers} #{inspect network}"

    network = case Network.update_peers(network, overlay_peers) do
      :no_change ->
        Logger.debug "[switchboard] #{inspect overlay} no change: #{inspect overlay_peers} vs #{inspect Network.peers(network)}"
        network
      {:changed, network} ->
        Logger.debug "[switchboard] #{inspect overlay} changed: #{inspect network}"
        # NB: No ^pin - reassigned 'network'
        case overlay do
          "watson" -> :ok
          _ -> for event <- [:connect_local_peers, :gossip_peers], do: send self(), {event, overlay}
        end
        network
    end

    {:noreply, %{state | networks: Map.put(networks, overlay, network)}}
  end

  @doc """
  Handle a message addressed to me.
  """
  def handle_publish(["node", host], msg, state) do
    myself = SentinelCore.hostname()
    handle_node_publish(myself, host, msg, state)
  end

  def handle_publish(["iot-2", "type", _device_type, "id", _device_id, "cmd", command_id, "fmt", fmt_string], msg, state) do
    decoded_msg = case fmt_string do
      "bin" -> :erlang.binary_to_term(msg)
      "txt"-> msg
      "json"-> msg
      _ -> "Bad datatype"
    end
    Logger.info "Watson command: " <> command_id
    Logger.info "msg: #{inspect decoded_msg}"
    case command_id do
      "ping_update" -> handle_ping_update(decoded_msg, state)
      _ -> "Bad command"
    end
    {:noreply, state}
  end

  def handle_publish(topic, message, state) do
    Logger.warn "[switchboard] unhandled publish message #{inspect topic} #{inspect message}"
    {:noreply, state}
  end

  def handle_ping_update(msg_string, state) do
    device_id = state.watson_opts.device_id
    cloud_gateways = List.delete(String.split(msg_string, "_"), device_id)
    #update watson network with cloud gateways
    handle_publish(["swarm", "update", "watson"], {:unknown, cloud_gateways}, state)
  end

  defp handle_node_publish(myself, host, msg, state) when myself == host do
    Logger.warn "[switchboard] unhandled message intended for me (#{inspect myself}): #{inspect msg}"
    {:noreply, state}
  end

  defp handle_node_publish(myself, host, msg, state) do
    Logger.warn "[switchboard] unhandled message for peer (#{inspect host}) not intended for me (#{inspect myself}): #{inspect msg}"
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
