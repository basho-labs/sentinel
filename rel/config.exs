# Import all plugins from `rel/plugins`
# They can then be used by adding `plugin MyPlugin` to
# either an environment, or release definition, where
# `MyPlugin` is the name of the plugin module.
Path.join(["rel", "plugins", "*.exs"])
|> Path.wildcard()
|> Enum.map(&Code.eval_file(&1))

use Mix.Releases.Config,
    # This sets the default release built by `mix release`
    default_release: :default,
    # This sets the default environment used by `mix release`
    default_environment: Mix.env()

# For a full list of config options for both releases
# and environments, visit https://hexdocs.pm/distillery/configuration.html


# You may define one or more environments in this file,
# an environment's settings will override those of a release
# when building in that environment, this combination of release
# and environment configuration is called a profile

environment :dev do
  set dev_mode: true
  set include_erts: false
  set cookie: :".z<Ys[K]DJFG~<lz,aYu5uNy/,HbsHck6,%[?Od4>$ez6uZzLikv4E6Ni{:r7kc|"
end

environment :prod do
  set include_erts: true
  set include_src: false
  set cookie: :"9[vb=dn^buIUm=;jSBK]X8,Xnmlm%1w04Hl*kI7&*&ZA.gW.,Lwrs}@]B$*bb_P7"
end

# You may define one or more releases in this file.
# If you have not set a default release, or selected one
# when running `mix release`, the first release in the file
# will be used by default

release :sentinel do
  set version: "0.1.0"
  set applications: [
    sentinel_core: :permanent,
    sentinel_router: :permanent
  ]
end

