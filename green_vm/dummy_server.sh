#!/bin/bash -xeu
set -o pipefail

while true; do echo "The time is" $(date) | nc -l 27017; done
