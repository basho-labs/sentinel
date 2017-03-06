defmodule SentinelCore.Peer do
  use GenServer
  require Logger

  def start_link(name, opts \\ []) do
    [host, port] = case String.split(name, ":") do
      [host] -> [host, 1883]
      [host, port] -> [host, String.to_integer(port)]
    end
    name = String.to_atom(name)

    GenServer.start_link(__MODULE__, [name, host, port, opts], name: name)
  end
  
  def init([name, host, port, opts]) do
    connect_opts = [
      {:host, String.to_charlist(host)},
      {:port, port},
      {:client_id, System.get_env("HOSTNAME")},
      {:keepalive, 300},
      {:clean_sess, false}
    ] ++ opts
    Logger.debug "[peer] connection options: #{inspect connect_opts}"

    send self(), {:connect, connect_opts}

    {:ok, %{
      name: name, 
      host: host,
      port: port,
      options: connect_opts,
      metadata: %{}
    }}
  end

  def get_name(%{:name => name} = _state) do
    name
  end

  def handle_call({:get_metadata, name}, _from, %{:metadata => metadata} = state) do
    {:reply, Map.get(metadata, name), state}
  end

  def handle_call({:set_metadata, name, newval}, _from, %{:metadata => metadata} = state) do
    {oldval, metadata} = Map.get_and_update(metadata, name, fn oldval -> {oldval, newval} end)
    {:reply, oldval, %{state | metadata: metadata}}
  end

  def handle_call({:sync_send, topic, msg, pubopts}, _from, %{:client => client} = state) do
    to_send = {System.get_env("HOSTNAME"), msg}
    result = :emqttc.sync_publish(client, topic, :erlang.term_to_binary(to_send), pubopts)
    {:reply, result, state}
  end

  def handle_call(msg, state) do
    Logger.debug "[peer] unhandled call message: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:connect, connect_opts}, state) do
    {:ok, remote_client} = :emqttc.start_link(connect_opts)
    Process.link remote_client
    Logger.debug "[peer] connected to: #{inspect remote_client}"
    {:noreply, Map.put(state, :client, remote_client)}
  end

  def handle_info({:mqttc, client, :connected}, %{:name => name} = state) do
    Logger.debug "[peer] MQTT client connected #{inspect client}"
    case name do
      :localhost ->
        for t <- ["swarm/#", "node/#"], do: :emqttc.subscribe(client, t, :qos1)
      _peer ->
        :emqttc.subscribe(client, "node/" <> SentinelCore.hostname(), :qos1)
    end
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, state) do
    Logger.debug "[peer] MQTT client disconnected #{inspect client}"
    {:noreply, state}
  end

  def handle_info({:send, topic, msg}, state) do
    handle_info({:send, topic, msg, []}, state)
  end

  def handle_info({:send, topic, msg, pubopts}, %{:client => client} = state) do
    to_send = {SentinelCore.hostname(), msg}
    :emqttc.publish(client, topic, :erlang.term_to_binary(to_send), pubopts)
    {:noreply, state}
  end

  def handle_info({:publish, topic, msg}, state) do
    Logger.debug "[peer] forwarding #{inspect topic} #{inspect msg} to switchboard"
    send SentinelCore.Switchboard, {:publish, topic, msg}
    {:noreply, state}
  end
  
  def handle_info(msg, state) do
    Logger.debug "[peer] unhandled info message: #{inspect msg}"
    send SentinelCore.Switchboard, msg
    {:noreply, state}
  end

end
