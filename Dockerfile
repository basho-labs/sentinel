FROM jbrisbin/elixir:ubuntu-16.04

RUN apt-get update
RUN apt-get install -y erlang-src build-essential-

COPY . /usr/src/sentinel_core
WORKDIR /usr/src/sentinel_core

ENV LANG en_US.UTF-8
ENV ELIXIR_ERL_OPTIONS "+pc unicode"

RUN mix deps.get
RUN MIX_ENV=prod mix release

RUN cp -R _build/prod/rel/sentinel_core /opt/sentinel
RUN rm -rf /var/lib/apt/lists/* /tmp/* /usr/src/*

COPY mosquitto.conf /etc/mosquitto/conf.d/user.conf
EXPOSE 1883

COPY start.sh /opt/sentinel/start.sh
WORKDIR /opt/sentinel
CMD /opt/sentinel/start.sh