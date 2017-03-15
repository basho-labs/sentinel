defmodule SentinelCore do
  @moduledoc """
  Documentation for SentinelCore.
  """
  require Logger

  alias SentinelCore.PeerSupervisor
  alias SentinelRouter.Network

  def hostname do
    case System.get_env("HOSTNAME") do
        nil ->
          {:ok, hn} = :inet.gethostname()
          List.to_string(hn)
        hn  -> hn
    end
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
    %{:networks => networks} = state
    :ok = SentinelCore.ping_watson(after_time, networks)
    {:ok, state}
  end

  def ping_watson(after_time, networks) do
    case Map.get(networks, "watson") do
      nil ->
        Logger.debug "[core] pinging watson"
        case Process.whereis(String.to_atom("watson")) do
          nil -> Logger.debug "[core] watson client not ready"
          pid -> send pid, {:ping}
        end
        Process.send_after(SentinelCore.Switchboard, {:ping_watson, after_time}, after_time)
      _watson_gws ->
        :ok
    end
    :ok
  end

  def connect_local_peers(networks, overlay) do
    {:ok, local_peers} = SentinelCore.get_local_peers(overlay, networks)
    {:ok, not_connected} = SentinelCore.get_unconnected_peers(local_peers)
    Logger.debug "[core] not connected: #{inspect not_connected}"
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
        Logger.debug "[core] is_gateways changed: #{inspect was_gw} -> #{inspect on_many_networks}"
      true -> :ok
    end
    {:ok, state}
  end

  def is_gateway(networks) do
    is_gateway = Map.size(networks) >= 2
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
    Logger.debug "[core] joining node #{inspect peer} with #{inspect state.networks}"
    {:ok, networks} = SentinelCore.add_to_network(state.networks, overlay, peer)
    Logger.debug "[core] networks: #{inspect networks}"
    state = %{state | networks: networks}
    send SentinelCore.Switchboard, {:connect_local_peers, overlay}
    for an_overlay <- Map.keys(state.networks), an_overlay != "watson" do
      send SentinelCore.Switchboard, {:connect_local_peers, an_overlay}
    end
    {:ok, state}
  end

  def add_to_network(networks, overlay, peer) do
    network = Map.get(networks, overlay, Network.new([SentinelCore.hostname()]))
    network = Network.add(network, peer)
    networks = Map.put(networks, overlay, network)
    {:ok, networks}
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
    Logger.debug "[core] swarm/update/#{inspect overlay}: #{inspect overlay_peers} #{inspect network}"
    {changed, updated_network} = case Network.update_peers(network, overlay_peers) do
      :no_change ->
        Logger.debug "[core] #{inspect overlay} no change: #{inspect overlay_peers} vs #{inspect Network.peers(network)}"
        {false, Map.get(networks, overlay)}
      {:changed, new_network} ->
        Logger.debug "[core] #{inspect overlay} changed: #{inspect new_network}"
        {true, new_network}
    end
    case changed do
      false ->
        :ok
      true ->
        for an_overlay <- Map.keys(state.networks), an_overlay != "watson" do
          send SentinelCore.Switchboard, {:connect_local_peers, an_overlay}
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
    Logger.warn "[core] unhandled message intended for me (#{inspect SentinelCore.hostname()}): #{inspect msg}"
    {:ok, state}
  end

  def on_node_publish(host, msg, state) do
    Logger.warn "[core] message for peer (#{inspect host}): #{inspect msg}"
    {:ok, peers} = SentinelCore.get_all_local_peers(state.networks)
    {:ok, state} = case SentinelCore.node_locality(host, peers) do
      {:ok, :me} -> SentinelCore.node_message_for_me(msg, state)
      {:ok, :local} ->
        Logger.info "[core] peer (#{inspect host}) is local, doing nothing"
        {:ok, state}
      {:ok, :nonlocal} -> SentinelCore.forward_message(host, msg, state)
    end
    {:ok, state}
  end

  def get_all_local_peers(networks) do
    local_peers = []
    local_peers = for {_net_name, net} <- Map.to_list(networks), do: local_peers ++ Network.peers(net)
    peers = List.flatten(local_peers, [])
    Logger.debug "[core] local peers: (#{inspect peers})"
    {:ok, peers}
  end

  @spec node_locality(String.t, list(String.t)) :: {:ok, :me | :local | :nonlocal}
  def node_locality(host, local_peers) do
    locality = cond do
      host == SentinelCore.hostname() -> :me
      Enum.member?(local_peers, host) -> :local
      true -> :nonlocal
    end
    Logger.debug "[core] node locality for (#{inspect host}) is #{inspect locality}"
    {:ok, locality}
  end

  def on_watson_publish(["iot-2", "type", _device_type, "id", _device_id, "cmd", command_id, "fmt", fmt_string], msg, state) do
    decoded_msg = case fmt_string do
      "bin" -> :erlang.binary_to_term(msg)
      "txt"-> msg
      "json"-> msg
      _ -> "Bad datatype"
    end
    Logger.debug "[core] recieved watson command (#{command_id}) with payload: #{inspect decoded_msg}"
    {:ok, state} = case command_id do
      "ping_update" -> ping_update(decoded_msg, state)
      "message" -> on_message_from_watson(decoded_msg, state)
      _ -> {:ok, state}
    end
    {:ok, state}
  end

  def on_message_from_watson(decoded_msg, state) do
    {_from, {message_type, {host, msg}}} = decoded_msg
    case message_type do
      :find_request -> send :localhost, {:send, "send/find/request/"<>host, msg}
      :send_message -> send :localhost, {:send, "send/message/"<>host, msg}
      _ -> :ok
    end
    {:ok, state}
  end

  def ping_update(msg_string, state) do
    device_id = System.get_env("DEVICE_ID")
    [gws_string, hns_string] = String.split(msg_string, ":")
    cloud_gateways = List.delete(String.split(gws_string, "&"), device_id)
    cloud_hostnames = List.delete(String.split(hns_string, "&"), SentinelCore.hostname())
    {:ok, state} = SentinelCore.update_hostname_map(cloud_gateways, cloud_hostnames, state)
    msg = :erlang.term_to_binary({:unknown, {cloud_gateways, false}})
    {:ok, state} = SentinelCore.on_swarm_update(["swarm", "update", "watson"], msg, state)
    {:ok, state}
  end

  def update_hostname_map(cloud_gateways, cloud_hostnames, state) do
    hn_map = Map.get(state, :hostname_map, %{})
    Logger.debug "[core] updating hostname_map: #{inspect hn_map}"
    zipped = Enum.zip(cloud_hostnames, cloud_gateways)
    hn_map = Enum.reduce zipped, hn_map, fn x, acc ->
      {hn, gw} = x
      Map.put(acc, hn, gw)
    end
    Logger.debug "[core] updated hostname_map: #{inspect hn_map}"
    state = Map.put(state, :hostname_map, hn_map)
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
        Logger.debug "[core] cannot forward to watson, no watson peers"
    [peer] ->
        Logger.debug "[core] forward to watson peer: #{inspect peer}"
        {format, new_msg} = case is_binary(msg) do
          true -> {"bin", :erlang.term_to_binary({host, :erlang.binary_to_term(msg)})}
          false -> {"bin", :erlang.term_to_binary({host, msg})}
        end
        send :watson, {:send, peer, format, new_msg}
    _ ->
        Logger.debug "[core] too many watson peers, don't know what to do"
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

  # messages either come in from a user as a string or from another node as a binary: {from, {list_of_hops, msg}}
  def send_message(host, msg, state) do
    {:ok, peers} = SentinelCore.get_all_local_peers(state.networks)
    {:ok, state} = case SentinelCore.node_locality(host, peers) do
      {:ok, :me} -> SentinelCore.recieve_send_message(host, msg, state)
      {:ok, :local} -> SentinelCore.forward_send_message_local(host, msg, state)
      {:ok, :nonlocal} -> SentinelCore.forward_send_message_nonlocal(host, msg, state)
    end
    {:ok, state}
  end

  # message is {from, {[], msg}
  def recieve_send_message(host, msg, state) do
    {_from ,{[], decoded_msg}} = :erlang.binary_to_term(msg)
    Logger.debug "[core] message recieved for me (#{host}): #{inspect decoded_msg}"
    {:ok, state} = case decoded_msg do
      {:find_request_repsonse, requested_path} -> SentinelCore.find_request_response(requested_path, state)
      _ -> Logger.warn "[core] unhandled message intended for me (#{host}): #{inspect msg}"
           {:ok, state}
    end
    {:ok, state}
  end

  # message is {from, {[], msg}
  def forward_send_message_local(host, msg, state) do
    {_from ,{[], decoded_msg}} = :erlang.binary_to_term(msg)
    Logger.debug "[core] forwarding message to local peer (#{host}): #{inspect decoded_msg}"
    send String.to_atom(host), {:send, "send/message/"<>host, {[], decoded_msg}}
    {:ok, state}
  end

  def forward_send_message_nonlocal(host, msg, state) do
    {_from ,{path, decoded_msg}} = :erlang.binary_to_term(msg)
    Logger.debug "[core] forwarding message to non-local peer (#{host}): #{inspect :erlang.binary_to_term(msg)}"
    {:ok, state} = cond do
      SentinelCore.msg_has_path(msg) -> SentinelCore.send_msg_next_hop(host, msg, state)
      host in Map.keys(state.hostname_map) -> send :watson, {:send_message, Map.get(state.hostname_map, host), host, {path, decoded_msg}}
                                              {:ok, state}
      true -> SentinelCore.find_path_to_target_and_send(host, msg, state)
    end
    {:ok, state}
  end

  @spec msg_has_path(binary) :: boolean
  def msg_has_path(msg) do
    {_from ,{path, _decoded_msg}} = :erlang.binary_to_term(msg)
    has_path = Kernel.length(path) >= 1
    has_path
  end

  # pop a hop of the front of the path list and send to that hop
  def send_msg_next_hop(host, msg, state) do
    {_from ,{path, decoded_msg}} = :erlang.binary_to_term(msg)
    [next_hop | rest_of_path] = path
    Logger.debug "[core] forwarding message for peer (#{host}) to next hop (#{next_hop}) in path (#{inspect path})"
    case Atom.to_string(next_hop) in Map.keys(state.hostname_map) do
      true -> send :watson, {:send_message, Map.get(state.hostname_map, Atom.to_string(next_hop)), host, {rest_of_path, decoded_msg}}
      false -> send next_hop, {:send, "send/message/"<>host, {rest_of_path, decoded_msg}}
    end
    {:ok, state}
  end

 # message will be {from, {[], msg}}
  def find_path_to_target_and_send(host, msg, state) do
    Logger.debug "[core] no path message to #{host}, finding path"
    paths = Map.get(state, :paths, %{})
    target_path = Map.get(paths, String.to_atom(host), [])
    {:ok, state} = cond do
      target_path != [] -> SentinelCore.get_path_and_send(host, msg, state)
      target_path == [] -> SentinelCore.queue_msg_and_find_path(host, msg, state)
    end
    {:ok, state}
    end

  def queue_msg_and_find_path(host, msg, state) do
    # store msg in pending msgs
    Logger.debug "[core] path message to #{host} not yet discovered"
    {_from ,{[], decoded_msg}} = :erlang.binary_to_term(msg)
    pending = Map.get(state, :pending_msgs, %{})
    host_msgs = Map.get(pending, String.to_atom(host), [])
    pending = Map.put(pending, String.to_atom(host), host_msgs ++ [decoded_msg])
    state = Map.put(state, :pending_msgs, pending)
    Logger.debug "[core] message added to pending message queue: #{inspect Map.get(pending, String.to_atom(host), [])}"
    Logger.debug "[core] initiating find request for path to #{host}"
    send :localhost, {:send, "send/find/request/"<>host, []}
    {:ok, state}
  end

  def get_path_and_send(host, msg, state) do
    target_paths = Map.get(state.paths, String.to_atom(host), [])
    {first_path, _other_paths} = List.pop_at(target_paths, 0)
    Logger.debug "[core] path to #{host}) already discovered, using: #{inspect first_path}"
    {_from ,{[], decoded_msg}} = :erlang.binary_to_term(msg)
    msg = :erlang.term_to_binary({:from, {first_path, decoded_msg}})
    {:ok, state} = SentinelCore.send_msg_next_hop(host, msg, state)
    {:ok, state}
  end

  def find_request(host, msg, state) do
    Logger.debug "[core] recieved find request for #{host}"
    {:ok, state} = cond do
      host == SentinelCore.hostname() -> SentinelCore.respond_to_find_request(host, msg, state)
      true -> SentinelCore.forward_find_request(host, msg, state)
    end
    {:ok, state}
  end

  # requested_path will looks like [:requester, :hop1, ... , :hopN, :target]
  def respond_to_find_request(host, msg, state) do
    {_from , path} = :erlang.binary_to_term(msg)
    requested_path = path++[String.to_atom(host)]
    {requester, gw_hops} = List.pop_at(path, 0)
    return_path = Enum.reverse(gw_hops)
    Logger.debug "[core] responding to find request for me (#{host})"
    Logger.debug "[core] sending find response back to #{Atom.to_string(requester)} with path: #{inspect requested_path}"
    send :localhost, {:send, "send/message/"<>Atom.to_string(requester), {return_path, {:find_request_repsonse, requested_path}}}
    {:ok, state}
  end

  # forward to all local gateways that have not already seen the message
  def forward_find_request(host, msg, state) do
    {:ok, peers} = SentinelCore.get_all_local_peers(state.networks)
    {:ok, state} = case SentinelCore.node_locality(host, peers) do
      {:ok, :me} -> Logger.debug "[core] error: find request for me (#{host})"
      {:ok, :local} -> SentinelCore.forward_find_request_local(host, msg, state)
      {:ok, :nonlocal} -> SentinelCore.forward_find_request_nonlocal(host, msg, state)
    end
    {:ok, state}
  end

  def forward_find_request_local(host, msg, state) do
    {_from , path} = :erlang.binary_to_term(msg)
    hostname_atom = String.to_atom(SentinelCore.hostname())
    Logger.debug "[core] local: forwarding find request for #{host} to #{host}"
    send Process.whereis(String.to_atom(host)), {:send, "send/find/request/"<>host, path++[hostname_atom]}
    {:ok, state}
  end

  def forward_find_request_nonlocal(host, msg, state) do
    {_from , path} = :erlang.binary_to_term(msg)
    hostname_atom = String.to_atom(SentinelCore.hostname())
    Logger.debug "[core] gateways: #{inspect Map.keys(state.gateways)}"
    for gw <- Map.keys(state.gateways), not Enum.member?(path, gw) do
      Logger.debug "[core] nonlocal: forwarding find request for #{host} to #{gw}"
      send gw, {:send, "send/find/request/"<>host, path++[hostname_atom]}
    end

    if Map.get(state.networks, "watson") do
      watson_peers = Network.peers(Map.get(state.networks, "watson"))
      for watson_peer <- watson_peers do
        [default | _rest] = path
        {hn_of_peer, _peer} = Enum.find(state.hostname_map, default, fn{_k, v} -> v == watson_peer end)
        if not Enum.member?(path, String.to_atom(hn_of_peer)) do
          Logger.debug "[core] nonlocal: forwarding find request for #{host} to #{watson_peer}"
          send :watson, {:find_request, watson_peer, host, path++[hostname_atom]}
        end
      end
    end
    {:ok, state}
  end

  # requested_path will looks like [:requester, :hop1, ... , :hopN, :target]
  def find_request_response(requested_path, state) do
    {target, requested_path} = List.pop_at(requested_path, -1)
    {_requester, requested_path} = List.pop_at(requested_path, 0)
    Logger.debug "[core] recieved response to find request for #{target}"
    paths = Map.get(state, :paths, %{})
    target_paths = Map.get(paths, target, [])
    updated_target_paths = cond do
      Enum.member?(target_paths, requested_path) -> target_paths
      not Enum.member?(target_paths, requested_path) -> target_paths++[requested_path]
    end
    cond do
      target_paths == updated_target_paths -> Logger.debug "[core] ignoring duplicate path: #{inspect requested_path}"
      target_paths != updated_target_paths -> Logger.debug "[core] adding path to #{target}: #{inspect requested_path}"
    end

    paths = Map.put(paths, target, updated_target_paths)
    state = Map.put(state, :paths, paths)
    {:ok, state} = SentinelCore.update_and_send_pending(target, state)
    {:ok, state}
  end

  def update_and_send_pending(target, state) do
    pending = Map.get(state, :pending_msgs, %{})
    target_pending_msgs = Map.get(pending, target, [])
    new_pending_msgs = Map.put(pending, target, [])
    state = Map.put(state, :pending_msgs, new_pending_msgs)
    cond do
      target_pending_msgs != [] -> Logger.debug "[core] sending all pending messages for #{inspect target}: #{inspect target_pending_msgs}"
      true -> :ok
    end
    for msg <- target_pending_msgs, do: SentinelCore.message(Atom.to_string(target), msg, state)
    {:ok, state}
  end

  def message(host, msg, state) do
    Logger.debug "[core] sending message to #{host}: #{inspect msg}"
    send :localhost, {:send, "send/message/"<>host, {[], msg}}
    {:ok, state}
  end

end
