defmodule SentinelCore do
  @moduledoc """
  Documentation for SentinelCore.
  """
  require Logger

  alias SentinelCore.PeerSupervisor
  alias SentinelRouter.Network

  def hostname do
    System.get_env("HOSTNAME")
  end

  def default_gateway do
    System.get_env("SENTINEL_DEFAULT_GATEWAY")
  end

  def default_network do
    System.get_env("SENTINEL_DEFAULT_NETWORK")
  end

  def join_gw_or_watson(state) do
    state = Kernel.update_in(state[:networks][SentinelCore.default_network()], fn _ -> Network.new([SentinelCore.hostname()]) end)
    state = case SentinelCore.default_gateway() do
      nil ->
        if System.get_env("ORG_ID") != nil do
          send SentinelCore.Switchboard, :connect_to_watson
        end
        state
      gw ->
        send SentinelCore.Switchboard, :join_default_swarm
        %{state | gateway: String.to_atom(gw)}
    end
    {:ok, state}
  end

  def connect_and_start_pinging_watson(after_time, state) do
    PeerSupervisor.connect_watson("watson")
    {:ok, state} = SentinelCore.ping_watson(after_time, state)
    {:ok, state}
  end

  def ping_watson(after_time, state) do
    %{:networks => networks} = state
    case Map.get(networks, "watson") do
      nil ->
        Logger.debug "Pinging Watson"
        case Process.whereis(String.to_atom("watson")) do
          nil -> Logger.debug "Watson client not ready"
          pid -> send pid, {:ping}
        end
        Process.send_after(SentinelCore.Switchboard, {:ping_watson, after_time}, after_time)
      _watson_gws ->
        :ok
    end
    {:ok, state}
  end

  def connect_local_peers(networks, overlay) do
    {:ok, local_peers} = SentinelCore.get_local_peers(overlay, networks)
    {:ok, not_connected} = get_unconnected_peers(local_peers)
    Logger.debug "[switchboard] not connected: #{inspect not_connected}"
    for p <- not_connected, do: PeerSupervisor.connect(p)
    send SentinelCore.Switchboard, {:gossip_peers, overlay}
    :ok
  end

  def get_local_peers(overlay, networks) do
    network = Map.get(networks, overlay)
    local_peers = Network.peers(network)
    {:ok, local_peers}
  end

  def get_unconnected_peers(local_peers) do
    not_connected = Enum.filter(local_peers, fn p ->
      p != SentinelCore.hostname() and Process.whereis(String.to_atom(p)) == nil
      end)
    {:ok, not_connected}
  end

  def gossip_peers(overlay, state) do
    {:ok, local_peers} = SentinelCore.get_local_peers(overlay, state.networks)
    {:ok, state} = SentinelCore.become_gateway(state)
    pubopts = [{:qos, 1}, {:retain, true}]
    msg = {:send, "swarm/update/" <> overlay, {local_peers, state.is_gateway}, pubopts}
    :ok = SentinelCore.send_msg_all(local_peers, msg)
    {:ok, state}
  end

  def become_gateway(state) do
    was_gw = state.is_gateway
    {:ok, on_many_networks} = SentinelCore.is_gateway(state.networks)
    state = %{state | is_gateway: on_many_networks}
    cond do
      (was_gw or on_many_networks) and not (was_gw and on_many_networks) ->
        Logger.debug "is_gateways changed: #{inspect was_gw} -> #{inspect on_many_networks}"
      true -> :ok
    end
    {:ok, state}
  end

  def is_gateway(networks) do
    is_gateway = case Map.size(networks) do
      x when x >= 2 -> true
      x when x < 2 -> false
    end
    {:ok, is_gateway}
  end

  def send_msg_all(targets, msg) do
    for target <- targets, target != SentinelCore.hostname(), do: send String.to_atom(target), msg
    :ok
  end

  def join_default_swarm(gateway) do
    PeerSupervisor.connect(to_string(gateway))
    send gateway, {:send, "swarm/join/" <> SentinelCore.default_network(), SentinelCore.hostname()}
    :ok
  end

  @doc """
  Join the node to the named network and immediately try and connect to it.
  """
  def on_swarm_join(["swarm", "join", overlay], msg, state) do
    {_from, peer} = :erlang.binary_to_term(msg)

    Logger.debug "[switchboard] joining node #{inspect peer} with #{inspect state.networks}"

    {:ok, networks} = SentinelCore.add_to_network(state.networks, overlay, peer)

    Logger.debug "[switchboard] networks: #{inspect networks}"

    state = %{state | networks: networks}
    send SentinelCore.Switchboard, {:connect_local_peers, overlay}
    {:ok, state}
  end

  def add_to_network(networks, overlay, peer) do
    new_networks = Map.update(networks, overlay, Network.new([peer]), fn n ->
      Network.add(n, peer)
      end)
    {:ok, new_networks}
  end

  @doc """
  Update the overlay mesh.
  """
  def on_swarm_update(["swarm", "update", overlay], msg, state) do
    %{:networks => networks} = state
    {from, {overlay_peers, is_gateway}} = :erlang.binary_to_term(msg)
    network = case Map.get(networks, overlay) do
      nil -> Network.new
      n -> n
    end

    {:ok, state} = SentinelCore.update_gateways(from, is_gateway, state)

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
          _ -> send SentinelCore.Switchboard, {:connect_local_peers, overlay}
        end
    end
    new_networks = Map.put(networks, overlay, updated_network)
    state = Map.put(state, :networks, new_networks)
    {:ok, state}
  end

  def update_gateways(from, is_gateway, state) do
    gws = state.gateways
    gws = case is_gateway do
      true -> Map.put_new(gws, String.to_atom(from), %{})
      false -> gws
    end
    state = %{state | gateways: gws}
    {:ok, state}
  end

  def node_message_for_me(msg, state) do
    Logger.warn "[switchboard] unhandled message intended for me (#{inspect SentinelCore.hostname()}): #{inspect msg}"
    {:ok, state}
  end

  def on_node_publish(host, msg, state) do
    Logger.warn "[switchboard] message for peer (#{inspect host}): #{inspect msg}"
    {:ok, peers} = SentinelCore.get_all_local_peers(state.networks)
    Logger.info "[switchboard] All local peers: (#{inspect peers})"

    {:ok, state} = case SentinelCore.node_locality(host, peers) do
      :me -> SentinelCore.node_message_for_me(msg, state)
      :local -> Logger.info "[switchboard] peer (#{inspect host}) is local, doing nothing"
                {:ok, state}
      :nonlocal -> SentinelCore.forward_message(host, msg, state)
    end
    {:ok, state}
  end

  def get_all_local_peers(networks) do
    local_peers = []
    local_peers = for {_net_name, net} <- Map.to_list(networks), do: local_peers ++ Network.peers(net)
    peers = List.flatten(local_peers, [])
    {:ok, peers}
  end

  def node_locality(host, local_peers) do
    locality = cond do
      host == SentinelCore.hostname() -> :me
      Enum.member?(local_peers, host) -> :local
      true -> :nonlocal
    end
    {:ok, locality}
  end

  def on_watson_publish(["iot-2", "type", _device_type, "id", _device_id, "cmd", command_id, "fmt", fmt_string], msg, state) do
    decoded_msg = case fmt_string do
      "bin" -> :erlang.binary_to_term(msg)
      "txt"-> msg
      "json"-> msg
      _ -> "Bad datatype"
    end

    Logger.info "Watson command: " <> command_id
    Logger.info "msg: #{inspect decoded_msg}"

    {:ok, state} = case command_id do
      "ping_update" -> ping_update(decoded_msg, state)
      "message" -> forward_from_watson(decoded_msg, state)
      _ -> {:ok, state}
    end
    {:ok, state}
  end

  def ping_update(msg_string, state) do
    device_id = System.get_env("DEVICE_ID")
    cloud_gateways = List.delete(String.split(msg_string, "_"), device_id)
    msg = :erlang.term_to_binary({:unknown, cloud_gateways})
    {:ok, state} = SentinelCore.on_swarm_update(["swarm", "update", "watson"], msg, state)
    {:ok, state}
  end

  def forward_message(host, msg, state) do
    %{:gateway => gw} = state
    {:ok, state} = case gw do
      nil -> forward_to_watson(host, msg, state)
      _any -> forward_to_gateway(host, msg, state)
    end
    {:ok, state}
  end

  #Assumes only one watson peer
  def forward_to_watson(host, msg, state) do
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
  {:ok, state}
  end

  def forward_to_gateway(host, msg, state) do
    %{:gateway => gateway} = state
    send gateway, {:send, "node/" <> host, msg}
    {:ok, state}
  end

  def forward_from_watson({target,msg}, state) do
    topic = "node/"<>target
    send :localhost, {:send, topic, msg}
    {:ok, state}
  end

  def send_message(host, msg, state) do
    {:ok, peers} = SentinelCore.get_all_local_peers(state.networks)
    {:ok, state} = case SentinelCore.node_locality(host, peers) do
      :me -> SentinelCore.recieve_send_message(msg, state)
      :local -> SentinelCore.forward_send_message_local(host, msg, state)
      :nonlocal -> SentinelCore.forward_send_message_nonlocal(host, msg, state)
    end
    {:ok, state}
  end

  def recieve_send_message(msg, state) do
    Logger.warn "[switchboard] unhandled message intended for me (#{inspect SentinelCore.hostname()}): #{inspect msg}"
    {:ok, state}
  end

  def forward_send_message_local(host, msg, state) do

  end

  def forward_send_message_nonlocal(host, msg, state) do

  end

  def find_request(host, msg, state) do

  end

  def find_response(host, msg, state) do


  end

end
