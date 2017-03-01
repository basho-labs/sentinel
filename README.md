# SentinelCore

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `sentinel_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:sentinel_core, "~> 0.1.0"}]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/sentinel_core](https://hexdocs.pm/sentinel_core).

## Running

Export the following:
```
export ORG_ID=your-org-id
export RELAY_API_KEY=relay-api-key
export RELAY_ID=id-for-the-relay
export RELAY_AUTH_TOKEN=relay-auth-token
export DEVICE_TYPE=device-type-for-gateways
export DEVICE_ID_A=gateway-a-device-id
export AUTH_TOKEN_A=gateway-a-auth-token
export DEVICE_ID_B=gateway-b-device-id
export AUTH_TOKEN_B=gateway-b-auth-token
```

Then run `docker-compose down && docker-compose build && docker-compose up -d`


