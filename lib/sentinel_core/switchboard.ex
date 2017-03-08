defmodule SentinelCore.Switchboard do
  @moduledoc """
  The Switchboard manages connections to local peers via MQTT subscriber. It handles incoming messages to join the swarm as well as updates to the peers when new nodes are connected. All subscribers send their messages through this GenServer so that remote subscribers can be easily created.
  """
  use GenServer
  require Logger

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
    Logger.debug "[switchboard] starting switchboard"
    {:ok, state} = SentinelCore.join_gw_or_watson(state)
    Logger.debug "[switchboard] starting with state: #{inspect state}"
    {:ok, state}
  end

  @doc """
  Create a client for Watson IoT and connect.
  """
  def handle_info(:connect_to_watson, state) do
    Logger.debug "[switchboard] Connecting to Watson"
    {:ok, _} = SentinelCore.connect_and_start_pinging_watson(5000, state)
    {:noreply, state}
  end

  def handle_info({:ping_watson, after_time}, state) do
    {:ok, _} = SentinelCore.ping_watson(after_time, state)
    {:noreply, state}
  end

  @doc """
  Join this node to the gateway node to "bootstrap" the swarm.
  """
  def handle_info(:join_default_swarm, state) do
    :ok = SentinelCore.join_default_swarm(state.gateway)
    {:noreply, state}
  end

  @doc """
  Connect to all known peers by creating subscribers for myself on their brokers.
  """
  def handle_info({:connect_local_peers, overlay}, %{:networks => networks} = state) do
    :ok = SentinelCore.connect_local_peers(networks, overlay)
    {:noreply, state}
  end

  @doc """
  Send the list of peers around to other nodes I know about to converge the cluster view.
  """
  def handle_info({:gossip_peers, overlay}, %{:networks => networks} = state) do
    :ok = SentinelCore.gossip_peers(overlay, networks)
    {:noreply, state}
  end

  @doc """
  Dispatch all Published messages on all topics to handler.
  Split the topic on "/" for easier matching.
  """
  def handle_info({:publish, topic, msg}, state) do
    {:ok, state} = case String.split(topic, "/") do
      ["swarm", "join", overlay] ->
        SentinelCore.on_swarm_join(["swarm", "join", overlay], msg, state)
      ["swarm", "update", overlay] ->
        SentinelCore.on_swarm_update(["swarm", "update", overlay], msg, state)
      ["node", host] ->
        SentinelCore.on_node_publish(host, msg, state)
      ["iot-2", "type", device_type, "id", device_id, "cmd", command_id, "fmt", fmt_string] ->
        SentinelCore.on_watson_publish(["iot-2", "type", device_type, "id", device_id, "cmd", command_id, "fmt", fmt_string], msg, state)
      _ -> Logger.warn "[switchboard] unhandled message: #{inspect msg}"
           {:ok, state}
    end
    {:noreply, state}
  end

  def handle_info({:mqttc, client, msg}, state) do
    Logger.warn "[switchboard] mqttc message from #{inspect client}: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn "[switchboard] unhandled message: #{inspect msg}"
    {:noreply, state}
  end

end
