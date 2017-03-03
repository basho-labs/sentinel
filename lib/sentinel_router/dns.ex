defmodule SentinelRouter.DNS do
  use GenServer
  @behaviour DNS.Server

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    {:ok, %{}}
  end

  def handle(record, {_ip, _}) do
    query = hd(record.qdlist)

    resource = %DNS.Resource{
      domain: query.domain,
      class: query.class,
      type: query.type,
      ttl: 0,
      data: {127, 0, 0, 1}
    }

    %{record | anlist: [resource]}
  end

end