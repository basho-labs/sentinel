#!/bin/bash

set -ex

python ./e2e_tester.py $1 $2

/bin/cat
