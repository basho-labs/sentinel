defmodule SentinelCore.WatsonPeer do
  use GenServer
  require Logger

  def start_link(name) do
    name = String.to_atom(name)
    GenServer.start_link(__MODULE__, [name], name: name)
  end

  def init([name]) do
    %{
      :org_id => org_id,
      :device_type => device_type,
      :device_id => device_id,
      :auth_token => auth_token
    } = watson_opts()
    client_id = "g:" <> org_id <> ":" <> device_type <> ":" <> device_id
    host = org_id <> ".messaging.internetofthings.ibmcloud.com"
    port = "1883"
    username = "use-token-auth"
    password = auth_token
    connect_opts = [
                   {:host, String.to_charlist(host)},
                   {:port, String.to_integer(port)},
                   {:client_id, client_id},
                   {:username, username},
                   {:password, password},
                   {:reconnect, {1, 120}},
                   {:keepalive, 0},
                    :auto_resub
                    ]
    Logger.debug "[watson peer] connection options: #{inspect connect_opts}"

    send self(), {:connect, connect_opts}

    {:ok, %{
      name: name,
      host: host,
      port: port,
      client_id: client_id,
      username: username,
      password: password,
      org_id: org_id,
      device_type: device_type,
      device_id: device_id,
      auth_token: auth_token,
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
    Logger.debug "[watson peer] unhandled call message: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:connect, connect_opts}, state) do
    {:ok, watson_client} = :emqttc.start_link(connect_opts)
    Process.link watson_client
    Logger.debug "[watson peer] connected to: #{inspect watson_client}"
    {:noreply, Map.put(state, :client, watson_client)}
  end

  def handle_info({:mqttc, watson_client, :connected}, state) do
    %{:device_type => device_type, :device_id => device_id} = state
    Logger.debug "[watson peer] MQTT client connected #{inspect watson_client}"
    :emqttc.subscribe(watson_client, "iot-2/type/"<> device_type <> "/id/" <> device_id <> "/cmd/+/fmt/+", :qos1)
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, state) do
    Logger.debug "[watson peer] MQTT client disconnected #{inspect client}"
    {:noreply, state}
  end

  def handle_info({:send, evt, format, msg}, state) do
    handle_info({:send, evt, format, msg, []}, state)
  end

  def handle_info({:send, evt, format, msg, pubopts}, %{:client => client} = state) do
    topic = "iot-2/type/"<> state.device_type <>"/id/"<> state.device_id <>"/evt/"<> evt <>"/fmt/" <> format
    :emqttc.publish(client, topic, msg, pubopts)
    {:noreply, state}
  end

  def handle_info({:publish, topic, msg}, state) do
    Logger.debug "[watson peer] forwarding #{inspect topic} #{inspect msg} to switchboard"
    send SentinelCore.Switchboard, {:publish, topic, msg}
    {:noreply, state}
  end

  def handle_info({:ping}, state) do
    topic = "iot-2/type/"<> state.device_type <>"/id/"<> state.device_id <>"/evt/ping/fmt/txt"
    :emqttc.publish(state.client, topic, SentinelCore.hoshostname())
    {:noreply, state}
  end

  def handle_info({:find_request, watson_peer, host, path_list}, state) do
    topic = "iot-2/type/"<> state.device_type <>"/id/"<> state.device_id <>"/evt/"<> watson_peer <>"/fmt/bin"
    msg = :erlang.term_to_binary({SentinelCore.hostname(), {:find_request, {host, path_list}}})
    :emqttc.publish(state.client, topic, msg)
    {:noreply, state}
  end

  def handle_info({:send_message, watson_peer, host, msg}, state) do
    topic = "iot-2/type/"<> state.device_type <>"/id/"<> state.device_id <>"/evt/"<> watson_peer <>"/fmt/bin"
    msg = :erlang.term_to_binary({SentinelCore.hostname(), {:send_message, {host, msg}}})
    :emqttc.publish(state.client, topic, msg)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug "[watson peer] unhandled info message: #{inspect msg}"
    send SentinelCore.Switchboard, msg
    {:noreply, state}
  end

  defp watson_opts() do
    org_id = System.get_env("ORG_ID")
    device_type = System.get_env("DEVICE_TYPE")
    device_id = System.get_env("DEVICE_ID")
    auth_token = System.get_env("AUTH_TOKEN")
    watson_opts = %{org_id: org_id, device_type: device_type, device_id: device_id, auth_token: auth_token}
    watson_opts
  end

end
