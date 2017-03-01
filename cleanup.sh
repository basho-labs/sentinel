#!/bin/bash

set -ex

docker rm $(docker ps -qaf label=swarm=dev)
docker rmi $(docker images -qaf dangling=true)
