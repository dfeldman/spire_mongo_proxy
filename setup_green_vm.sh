#!/bin/bash -xeu
set -o xtrace
set -o pipefail

source environment

# This is passed straight into the agent conf file
# Needs to NOT start with spiffe://
TRUST_DOMAIN="test.com"


cmds/get_trust_bundle.sh > spire_bootstrap.tmp

pushd green_vm
vagrant destroy -f
vagrant up

# First, set up OpenSSL just for testing connectivity
# This opens up a port with a self-signed cert on port 44330 just for testing purposes
vagrant ssh -- "openssl s_server -key key.pem -cert cert.pem -accept 44330 -www" &
sleep 1
# Make sure we can access port 44330 securely
curl -k https://localhost:44330

# Now we run an SSH service in the background to forward the SPIRE port into Kubernetes
nohup vagrant ssh -- -R 8081:$SPIRE_SERVER_IP:8081 -N &

# Set up a registration entry
# For now, just set up the root user to get a spiffe id test.com/green_vm
cmds/add_backend_registration_entry_unix.sh

# Next, we set up SPIRE itself, using the install_spire script that is installed as 
# part of the VM.
vagrant ssh -- sudo bash install_spire.sh ${TRUST_DOMAIN} localhost 8081 $(../cmds/generate_join_token.sh)

# Finally, install Envoy
vagrant ssh -- sudo bash install_envoy.sh spiffe://test.com/ns/default/sa/spire-istio-envoy 20001 27017

# Run the dummy server in the background
vagrant ssh -- bash -c "sudo nohup dummy_server.sh  > /dev/null 2>&1 </dev/null &"
