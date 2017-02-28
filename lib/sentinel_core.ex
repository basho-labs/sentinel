defmodule SentinelCore do
  @moduledoc """
  Documentation for SentinelCore.
  """

  
  def hostname do
    System.get_env("HOSTNAME")
  end

  def default_gateway do
    System.get_env("SENTINEL_DEFAULT_GATEWAY")
  end

  def default_network do
    System.get_env("SENTINEL_DEFAULT_NETWORK")
  end

end
