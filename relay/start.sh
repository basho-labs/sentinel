set -ex

python3 ./mqtt-message-relay.py $1 $2 $3 $4 &

/bin/cat