#!/bin/bash

#
# Copyright 2021 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

LOCAL_SETUP_DIR="$(dirname "${BASH_SOURCE[0]}")"
KCP_GLBC_DIR="${LOCAL_SETUP_DIR}/.."
source "${LOCAL_SETUP_DIR}"/.setupEnv

DO_BREW="false"

usage() { echo "usage: ./local-setup.sh -c <number of clusters> <-b>" 1>&2; exit 1; }
while getopts ":bc:" arg; do
  case "${arg}" in
    c)
      NUM_CLUSTERS=${OPTARG}
      ;;
    b)
      DO_BREW="true"
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

if [[ "$DO_BREW" == "true" ]]; then
  if [[ "${OSTYPE}" =~ ^darwin.* ]]; then
    ${SCRIPT_DIR}/macos/required_brew_packages.sh
  fi
else
  echo "skipping brew"
fi

source "${LOCAL_SETUP_DIR}"/.startUtils

if [ -z "${NUM_CLUSTERS}" ]; then
    usage
fi

set -e pipefail

trap cleanup EXIT 1 2 3 6 15

cleanup() {
  echo "Killing KCP"
  kill "$KCP_PID"
}

TEMP_DIR="./tmp"
KCP_LOG_FILE="${TEMP_DIR}"/kcp.log

KIND_CLUSTER_PREFIX="kcp-cluster-"
KCP_GLBC_CLUSTER_NAME="${KIND_CLUSTER_PREFIX}glbc-control"
GLBC_WORKSPACE=root:kuadrant

KUBECONFIG_KCP_ADMIN=.kcp/admin.kubeconfig
KUBECONFIG_KCP_GLBC=${TEMP_DIR}/kcp.kubeconfig

: ${KCP_VERSION:="release-0.8"}
KCP_SYNCER_IMAGE="ghcr.io/kcp-dev/kcp/syncer:${KCP_VERSION}"

: ${GLBC_DEPLOYMENTS_DIR=${KCP_GLBC_DIR}/config/deploy}
: ${KUSTOMIZATION_DIR=${GLBC_DEPLOYMENTS_DIR}/local}
: ${SYNC_TARGETS_DIR:=${GLBC_DEPLOYMENTS_DIR}/sync-targets}
: ${GLBC_DEPLOY_COMPONENTS:="cert-manager"}

for ((i=1;i<=$NUM_CLUSTERS;i++))
do
  CLUSTERS="${CLUSTERS}${KIND_CLUSTER_PREFIX}${i} "
done

mkdir -p ${TEMP_DIR}

[[ ! -z "$KUBECONFIG" ]] && KUBECONFIG="$KUBECONFIG" || KUBECONFIG="$HOME/.kube/config"

createCluster() {
  cluster=$1;
  port80=$2;
  port443=$3;
  cat <<EOF | ${KIND_BIN} create cluster --name ${cluster} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.22.7@sha256:1dfd72d193bf7da64765fd2f2898f78663b9ba366c2aa74be1fd7498a1873166
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: ${port80}
    protocol: TCP
  - containerPort: 443
    hostPort: ${port443}
    protocol: TCP
EOF

  #Note: these aren't used anymore, but leaving for now since the e2e tests still refers to a directory with these kubeconfigs in it
  ${KIND_BIN} get kubeconfig --name=${cluster} > ${TEMP_DIR}/${cluster}.kubeconfig
  ${KIND_BIN} get kubeconfig --internal --name=${cluster} > ${TEMP_DIR}/${cluster}.kubeconfig.internal
}

createKINDCluster() {
  [[ ! -z "$4" ]] && clusterName=${4} || clusterName=${1}
  echo "Creating KIND Cluster (${clusterName})"
  createCluster $1 $2 $3

  kubectl config use-context kind-${1}

  echo "Deploying Ingress controller to ${1}"
  VERSION=controller-v1.2.1
  curl https://raw.githubusercontent.com/kubernetes/ingress-nginx/"${VERSION}"/deploy/static/provider/kind/deploy.yaml | sed "s/--publish-status-address=localhost/--report-node-internal-ip-address/g" | kubectl apply -f -
  kubectl annotate ingressclass nginx "ingressclass.kubernetes.io/is-default-class=true"
  echo "Waiting for deployments to be ready ..."
  kubectl -n ingress-nginx wait --timeout=300s --for=condition=Available deployments --all
}

createKINDSyncTarget() {
  createKINDCluster $1 $2 $3 $4
  echo "Deploying kcp syncer to ${1}"
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl create namespace kcp-syncer --dry-run=client -o yaml | kubectl --kubeconfig=${KUBECONFIG_KCP_ADMIN} apply -f -
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${KUBECTL_KCP_BIN} workload sync ${clusterName} --kcp-namespace kcp-syncer --syncer-image=${KCP_SYNCER_IMAGE} --resources=ingresses.networking.k8s.io,services --output-file ${SYNC_TARGETS_DIR}/${clusterName}-syncer.yaml

  # Enable advanced scheduling
  echo "Enabling advanced scheduling"
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl annotate --overwrite synctarget ${clusterName} featuregates.experimental.workload.kcp.dev/advancedscheduling='true'
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl label --overwrite synctarget ${clusterName} kuadrant.dev/synctarget=${clusterName}
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl get synctargets ${clusterName} -o json | jq .metadata.annotations

  kubectl apply -f ${SYNC_TARGETS_DIR}/${clusterName}-syncer.yaml
}

#Delete existing kind clusters
clusterCount=$(${KIND_BIN} get clusters | grep ${KIND_CLUSTER_PREFIX} | wc -l)
if ! [[ $clusterCount =~ "0" ]] ; then
  echo "Deleting previous kind clusters."
  ${KIND_BIN} get clusters | grep ${KIND_CLUSTER_PREFIX} | xargs ${KIND_BIN} delete clusters
fi

#1. Start KCP
echo "Starting KCP, sending logs to ${KCP_LOG_FILE}"
${KCP_BIN} --v=9 start --run-controllers > ${KCP_LOG_FILE} 2>&1 &
KCP_PID=$!

if ! ps -p ${KCP_PID}; then
  echo "####"
  echo "---> KCP failed to start, see ${KCP_LOG_FILE} for info."
  echo "####"
  exit 1 #this will trigger cleanup function
fi

echo "Waiting for KCP server to be ready..."
wait_for "grep 'Bootstrapped ClusterWorkspaceShard root|root' ${KCP_LOG_FILE}" "kcp" "1m" "5"
sleep 5

(cd ${KCP_GLBC_DIR} && make generate-ld-config)

KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${KUBECTL_KCP_BIN} workspace use "root"
KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${KUBECTL_KCP_BIN} workspace create "kuadrant" --type universal --enter

#2. Setup workspace root:kuadrant
KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${SCRIPT_DIR}/deploy.sh -k "${KUSTOMIZATION_DIR}" -c "none"

#3. Create GLBC sync target and wait for it to be ready
createKINDCluster $KCP_GLBC_CLUSTER_NAME 8081 8444 "glbc"
kubectl apply -f ${GLBC_DEPLOYMENTS_DIR}/sync-targets/glbc-syncer.yaml

KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${KUBECTL_KCP_BIN} workspace use "${GLBC_WORKSPACE}"
KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl wait --timeout=300s --for=condition=Ready=true synctargets "glbc"

#4. Create User sync target clusters and wait for them to be ready
if [ -n "$CLUSTERS" ]; then
  echo "Creating $NUM_CLUSTERS kcp SyncTarget cluster(s)"
  port80=8082
  port443=8445
  for cluster in $CLUSTERS; do
    createKINDSyncTarget "$cluster" $port80 $port443
    port80=$((port80 + 1))
    port443=$((port443 + 1))
  done
  KUBECONFIG=${KUBECONFIG_KCP_ADMIN} kubectl wait --timeout=300s --for=condition=Ready=true synctargets $CLUSTERS
fi

#5.Create the GLBC APIExport after all the clusters have synced and deploy GLBC components (cert-manager)
KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${SCRIPT_DIR}/deploy.sh -k "${KUSTOMIZATION_DIR}" -c ${GLBC_DEPLOY_COMPONENTS}

#6. Miscellaneous local development specific steps

# Create the kcp-glbc namespace, kcp-glbc-controller-manager service account and generate a kubeconfig for access
KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ${SCRIPT_DIR}/create_glbc_kubeconfig.sh -o ${KUBECONFIG_KCP_GLBC}

# Apply the default glbc-ca issuer
kubectl --kubeconfig=${KUBECONFIG_KCP_ADMIN} apply -n kcp-glbc -f ./config/default/issuer.yaml

echo ""
echo "KCP PID          : ${KCP_PID}"
echo ""
echo "The kind k8s clusters have been registered, and KCP is running, now you should run kcp-glbc."
echo ""
echo "Run Option 1 (Local):"
echo ""
echo "       cd ${PWD}"
echo "       KUBECONFIG=${KUBECONFIG_KCP_GLBC} ./bin/kcp-glbc"
echo ""
echo "Run Option 2 (Deploy latest in KCP with monitoring enabled):"
echo ""
echo "       cd ${PWD}"
echo "       export KUBECONFIG=${KUBECONFIG_KCP_ADMIN}"
echo "       KUBECONFIG=${KUBECONFIG_KCP_ADMIN} ./utils/deploy.sh -k config/deploy/local"
echo "       KUBECONFIG=${KUBECONFIG} ./utils/deploy-observability.sh"
echo ""
echo "When glbc is running, try deploying the sample service:"
echo ""
echo "       cd ${PWD}"
echo "       export KUBECONFIG=${KUBECONFIG_KCP_ADMIN}"
echo "       ./bin/kubectl-kcp ws '~'"
echo "       kubectl apply -f config/deploy/local/kcp-glbc/apiexports/root-kuadrant-kubernetes-apibinding.yaml"
echo "       kubectl apply -f config/deploy/local/kcp-glbc/apiexports/root-kuadrant-glbc-apibinding.yaml"
echo "       kubectl apply -f samples/echo-service/echo.yaml"
echo ""
read -p "Press enter to exit -> It will kill the KCP process running in background"
