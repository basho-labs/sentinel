defmodule SentinelCore.Switchboard do
  use GenServer
  require Logger
  
  def start_link do
    state = %{
      hostname: hostname(), 
      peers: [], 
      peer_clients: [],
      gateway: nil,
      client: nil
    }
    GenServer.start_link(__MODULE__, state)
  end
  
  def init(%{:hostname => hostname} = state) do
    mqttc = connect(hostname, "localhost")

    :emqttc.subscribe(mqttc, "swarm/+", :qos0)

    {:ok, Map.put(state, :client, mqttc)}
  end

  def handle_info(:connect_local_swarm, %{:client       => _client, 
                                          :hostname     => hostname,
                                          :peers        => peers,
                                          :peer_clients => peer_clients} = state) do
    Logger.debug "subscribe to brokers on: #{inspect peers}"

    clients = for host <- peers, do: connect(hostname, host)
    Logger.debug "clients: #{inspect clients}"

    {:noreply, %{state | peer_clients: clients}}
  end

  def handle_info({:publish, "swarm/join", msg}, %{:client    => _client, 
                                                   :hostname  => _hostname,
                                                   :peers     => peers} = state) do
    Logger.info "joining node #{msg} with #{inspect peers}"
    send self(), :connect_local_swarm
    {:noreply, %{state | peers: [msg | peers]}}
  end

  def handle_info({:publish, "swarm/update", msg}, %{:client => _client} = state) do
    Logger.info "swarm/update: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:publish, "node/" <> host, msg}, %{:client   => _client, 
                                                      :hostname => hostname} = state) when host == hostname do
    Logger.info "msg to me: #{inspect msg}"
    {:noreply, state}
  end
  
  def handle_info({:publish, topic, msg}, %{:client => _client} = state) do
    Logger.info "topic: " <> topic
    Logger.info "msg: #{inspect msg}"
    {:noreply, state}
  end

  def handle_info({:mqttc, client, :disconnected}, %{:hostname => hostname} = state) do
    Logger.info "disconnected: #{inspect client}"
    {:noreply, state}
  end  

  def handle_info({:mqttc, client, :connected}, %{:hostname => hostname} = state) do
    topic = "node/" <> hostname
    Logger.info "subscribing to #{topic} with #{inspect client}"
    :emqttc.subscribe(client, topic, :qos1)
    {:noreply, state}
  end  
  
  defp hostname do
    System.get_env("HOSTNAME")
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
      :auto_resub
    ])
    Process.monitor remote_client

    Logger.debug "connected to: #{inspect remote_client}"
    remote_client
  end
  

end
