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
    Logger.debug "[switchboard] Connecting to Watson"
    PeerSupervisor.connect_watson("watson")
    after_time = 2000
    Process.send_after(self(), {:ping_watson, after_time}, after_time)
    {:noreply, state}
  end

  def handle_info({:ping_watson, after_time}, state) do
    %{:networks => networks} = state
    case Map.get(networks, "watson") do
        nil ->
          Logger.debug "Pinging Watson"
          case Process.whereis(String.to_atom("watson")) do
            nil -> Logger.debug "Watson client not ready"
            pid -> send pid, {:ping}
          end
          Process.send_after(self(), {:ping_watson, after_time}, after_time)
        _watson_gws ->
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
    for event <- [:gossip_peers], do: send self(), {event, overlay}
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
  def handle_publish(["swarm", "join", overlay], msg, %{:networks => networks} = state) do
    {_from, peer} = :erlang.binary_to_term(msg)
    Logger.debug "[switchboard] joining node #{inspect peer} with #{inspect networks}"
    networks = Map.update(networks, overlay, Network.new([peer]), fn n ->
      Network.add(n, peer)
    end)
    Logger.debug "[switchboard] networks: #{inspect networks}"
    state = %{state | networks: networks}
    for event <- [:connect_local_peers], do: send self(), {event, overlay}
    {:noreply, state}
  end


  @doc """
  Update the overlay mesh.
  """
  def handle_publish(["swarm", "update", overlay], msg, state) do
    %{:networks => networks} = state
    {_from, overlay_peers} = :erlang.binary_to_term(msg)
    network = case Map.get(networks, overlay) do
      nil -> Network.new
      n -> n
    end

    Logger.debug "[switchboard] swarm/update/#{inspect overlay}: #{inspect overlay_peers} #{inspect network}"

    {changed, updated_network} = case Network.update_peers(network, overlay_peers) do
      :no_change ->
        Logger.debug "[switchboard] #{inspect overlay} no change: #{inspect overlay_peers} vs #{inspect Network.peers(network)}"
        {false, Map.get(networks, overlay)}
      {:changed, new_network} ->
        Logger.debug "[switchboard] #{inspect overlay} changed: #{inspect new_network}"
        {true, new_network}
    end

    case changed do
      true ->
        :ok
      false ->
        case overlay do
          "watson" -> :ok
          _ -> for event <- [:connect_local_peers], do: send self(), {event, overlay}
        end
    end
    new_networks = Map.put(networks, overlay, updated_network)
    state = Map.put(state, :networks, new_networks)
    {:noreply, state}
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
      "message" -> handle_watson_message(decoded_msg, state)
      _ -> {:noreply, state}
    end
  end

  def handle_publish(topic, message, state) do
    Logger.warn "[switchboard] unhandled publish message #{inspect topic} #{inspect message}"
    {:noreply, state}
  end

  def handle_ping_update(msg_string, state) do
    device_id = System.get_env("DEVICE_ID")
    cloud_gateways = List.delete(String.split(msg_string, "_"), device_id)
    handle_publish(["swarm", "update", "watson"], :erlang.term_to_binary({:unknown, cloud_gateways}), state)
  end

  defp handle_watson_message({target,msg}, state) do
    topic = "node/"<>target
    send :localhost, {:send, topic, msg}
    {:noreply, state}
  end

  #messages for me
  defp handle_node_publish(myself, host, msg, state) when myself == host do
    Logger.warn "[switchboard] unhandled message intended for me (#{inspect myself}): #{inspect msg}"
    {:noreply, state}
  end

  #message not for me
  defp handle_node_publish(myself, host, msg, state) do
    Logger.warn "[switchboard] message for peer (#{inspect host}): #{inspect msg}"
    %{:networks => networks} = state
    local_peers = []
    local_peers = for {_net_name, net} <- Map.to_list(networks), do: local_peers ++ Network.peers(net)
    peers = List.flatten(local_peers, [])
    Logger.info "[switchboard] All local peers: (#{inspect peers})"

    case Enum.member?(peers, host) do
        true -> Logger.info "[switchboard] peer (#{inspect host}) is local, doing nothing"
                {:noreply, state}
        false -> forward_message(myself, host, msg, state)
    end
  end

  defp forward_message(myself, host, msg, state) do
    %{:gateway => gw} = state
    case gw do
      nil -> forward_watson(myself, host, msg, state)
      _any -> forward_gateway(myself, host, msg, state)
    end
  end

  #Assumes only one watson peer
  defp forward_watson(_myself, host, msg, state) do
  %{:networks => networks} = state
  watson_network = Map.get(networks, "watson")
  case Network.peers(watson_network) do
    [] ->
        Logger.info "[switchboard] Cannot forward to Watson, no Watson peers"
    [peer] ->
        Logger.info "[switchboard] Forward to Watson peer: #{inspect peer}"
        {format, new_msg} = case is_binary(msg) do
          true -> {"bin", :erlang.term_to_binary({host, :erlang.binary_to_term(msg)})}
          false -> {"bin", :erlang.term_to_binary({host, msg})}
        end
        send :watson, {:send, peer, format, new_msg}
    _ ->
        Logger.info "[switchboard] Too many Watson peers, don't know what to do"
  end
  {:noreply, state}
  end

  defp forward_gateway(_myself, host, msg, state) do
  %{:gateway => gateway} = state
  send gateway, {:send, "node/" <> host, msg}
  {:noreply, state}
  end

end
