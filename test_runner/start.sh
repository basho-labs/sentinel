#!/bin/bash

set -ex
sleep 10
pytest ./tester.py -s

/bin/cat
