#!/bin/bash -xeuo pipefail

SPIRE="https://github.com/spiffe/spire/releases/download/v0.12.1/spire-0.12.1-linux-x86_64-glibc.tar.gz"
ISTIO="istio-1.9.0"
FRONTEND_ID="spiffe://test.com/ns/default/sa/spire-istio-envoy"
BACKEND_ID="spiffe://test.com/backend"
TRUST_DOMAIN="spiffe://test.com"

# Check binaries: kind, kubectl, docker, helm
which kind || (echo "kind not found"; exit 1)
which kubectl || (echo "kubectl not found"; exit 1)
which helm || (echo "helm not found"; exit 1)
(helm version | grep "Version:\"v3.") || (echo "Helm is not version 3"; exit 1)
which docker || (echo "docker not found"; exit 1)
which vagrant || (echo "vagrant not found"; exit 1)

# First create the BLUE cluster
kind delete cluster --name=blue  # make sure we're starting from a blank slate
kind create cluster --name=blue --config=blue-kind-config.yaml
kind export kubeconfig --name=blue

# Install MetalLB on the BLUE cluster
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml
sleep 5
subnet=`cmds/get_docker_subnet.sh`
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${subnet}0.100-${subnet}0.150
EOF

# Download the current version of Istio. 
rm -rf $ISTIO
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.9.0 sh -

# Install Istio
$ISTIO/bin/istioctl x precheck
$ISTIO/bin/istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled

# Install useful utilities for demo purposes
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/addons/kiali.yaml
sleep 5
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/addons/kiali.yaml
kubectl apply -f $ISTIO/samples/addons/kiali.yaml
kubectl apply -f $ISTIO/samples/addons/jaeger.yaml
kubectl apply -f $ISTIO/samples/addons/grafana.yaml
kubectl apply -f $ISTIO/samples/addons/prometheus.yaml
# Ambassador ingress is nice for exposing any HTTP services
kubectl apply -f https://github.com/datawire/ambassador-operator/releases/latest/download/ambassador-operator-crds.yaml
kubectl apply -n ambassador -f https://github.com/datawire/ambassador-operator/releases/latest/download/ambassador-operator-kind.yaml
kubectl wait --timeout=180s -n ambassador --for=condition=deployed ambassadorinstallations/ambassador
# Sleep pod for use as a curl client
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.9/samples/sleep/sleep.yaml

# Install the SPIRE server, agents, and k8s-workload-registrar with all defaults
helm install spire charts/spire-chart
# LB so it can be accessed outside the cluster
kubectl apply -f util/spire-server-lb.yaml
# This helps with debugging in case the LB isn't working
kubectl apply -f util/spire-nodeport.yaml

# Wait for the LB to get created
sleep 5
# Get a join token for the SPIRE server
join_token=`cmds/generate_join_token.sh`
blue_ip=$(kubectl get svc/spire-server-lb-service -n spire -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')






# Set up the Vagrant vm
pushd green_vm

vagrant up 

# First, set up OpenSSL just for testing connectivity
# This opens up a port with a self-signed cert on port 44330 just for testing purposes
vagrant ssh green -- "openssl s_server -key key.pem -cert cert.pem -accept 44330 -www" &
# Make sure we can access port 44330 securely
curl -k https://localhost:44330

# Now install GetEnvoy, a useful wrapper for Envoy
vagrant ssh green -- "curl -L https://getenvoy.io/cli | sudo bash -s -- -b /usr/local/bin "

# Now install SPIRE. We only need the agent here but we have to download everything. 
vagrant ssh -- sudo yum install wget -y
vagrant ssh -- wget $SPIRE
vagrant ssh -- tar xvzf --no-overwrite-dir spire\*

# This establishes a network tunnel FROM port 8081 inside the Vagrant VM
# to port 8081 on the spire-server LB. This should not be needed if the LB is exposed publicly;
# It is for demo purposes.
nohup vagrant ssh -- -R 8081:$blue_ip:8081 -N &







# 13 Install the SPIRE agent on the GREEN cluster, point it it at the IP address and join token from step 10

# Install the gateway for the backend. We have to do this first so we have the IP address
# to point the frontend to.

kubectl apply -f util/backend-lb.yaml

green_ip=$(kubectl get svc/backend-lb-service -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Install the gateway for the frontend.
cmds/set_context_blue.sh
helm install --set mode=frontend \
             --set upstreamHost=$green_ip \
	     --set upstreamPort=443 \
	     --set backendSpiffeId="$BACKEND_ID" \
	     --set frontendSpiffeId="$FRONTEND_ID" \
	     --set trustDomain="$TRUST_DOMAIN" \ 
	     spire-istio-envoy-frontend charts/spire-istio-envoy/

cmds/set_context_blue.sh
cmds/add_backend_registration_entry.sh

# 18 Demonstrate that curl on the BLUE cluster can communicate with the echo server on the GREEN cluster.
cmds/set_context_blue.sh
cmds/run_test_command.sh

