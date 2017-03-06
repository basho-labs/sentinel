#!/bin/bash

service mosquitto start
tail -F /var/log/mosquitto/mosquitto.log &
bin/sentinel_core foreground