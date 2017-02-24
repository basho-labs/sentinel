#!/bin/bash

sleep 5

NODES=$(docker inspect -f '{{.Config.Hostname}}' $(docker ps -qf label=swarm=dev))

for node1 in $NODES; do
  for node2 in $NODES; do
    mosquitto_pub -q 1 -h $node1 -m hello -t node/$node2
  done
done