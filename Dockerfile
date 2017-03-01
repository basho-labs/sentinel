FROM debian:8

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN apt-get update
RUN apt-get install -y apt-transport-https curl git mosquitto

RUN echo "deb https://packages.erlang-solutions.com/debian jessie contrib" >>/etc/apt/sources.list
RUN curl -sO https://packages.erlang-solutions.com/debian/erlang_solutions.asc
RUN apt-key add erlang_solutions.asc
RUN apt-get update
RUN apt-get install -y elixir

COPY . /usr/src/sentinel_core
WORKDIR /usr/src/sentinel_core

ENV LANG en_US.UTF-8
ENV LC_CTYPE en_US.UTF-8
ENV ELIXIR_ERL_OPTIONS "+pc unicode"

RUN mix local.hex --force
RUN mix local.rebar --force
# RUN mix deps.get
RUN MIX_ENV=prod mix release

RUN cp -R _build/prod/rel/sentinel_core /opt/sentinel
RUN rm -rf /var/lib/apt/lists/* /tmp/* /usr/src/*

COPY mosquitto.conf /etc/mosquitto/conf.d/user.conf
EXPOSE 1883

COPY start.sh /opt/sentinel/start.sh
WORKDIR /opt/sentinel
CMD /opt/sentinel/start.sh