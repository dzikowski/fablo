#!/usr/bin/env bash

source "$FABLO_NETWORK_ROOT/fabric-k8s/scripts/util.sh"

deployCA() {
  local CA_ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"

  inputLog "Deploying $CA_ID ($CA_IMAGE:$CA_VERSION)"
  kubectl hlf ca create \
    --image="$CA_IMAGE" \
    --version="$CA_VERSION" \
    --storage-class="$STORAGE_CLASS" \
    --capacity=1Gi \
    --name="$CA_ID" \
    --enroll-id="$ENROLL_NAME" \
    --enroll-pw="$ENROLL_SECRET"
}

registerPeerUser() {
  local CA_ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"
  local ORG_MSP="$4"
  local PEER_SECRET="$ENROLL_SECRET"

  inputLog "Registering peer user for $ORG_MSP"
  kubectl hlf ca register \
    --name="$CA_ID" \
    --user=peer \
    --secret="$PEER_SECRET" \
    --type=peer \
    --enroll-id="$ENROLL_NAME" \
    --enroll-secret="$ENROLL_SECRET" \
    --mspid="$ORG_MSP"
}

registerAdminUser() {
  local CA_ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"
  local ORG_MSP="$4"
  local PEER_SECRET="$ENROLL_SECRET"

  inputLog "Registering admin user for $ORG_MSP"
  kubectl hlf ca register \
    --name="$CA_ID" \
    --user=admin \
    --secret="$PEER_SECRET" \
    --type=admin \
    --enroll-id="$ENROLL_NAME" \
    --enroll-secret="$ENROLL_SECRET" \
    --mspid="$ORG_MSP"
}

deployPeer() {
  local PEER_ID="$1"
  local ENROLL_SECRET="$2"
  local STATE_DB="$3"
  local CA_ID="$4"
  local ORG_MSP="$5"

  inputLog "Deploying $PEER_ID"
  kubectl hlf peer create \
    --statedb="$STATE_DB" \
    --image="$PEER_IMAGE" \
    --version="$PEER_VERSION" \
    --storage-class="$STORAGE_CLASS" \
    --enroll-id=peer \
    --enroll-pw="$ENROLL_SECRET" \
    --mspid="$ORG_MSP" \
    --capacity=5Gi \
    --name="$PEER_ID" \
    --ca-name="$CA_ID.$NAMESPACE" \
    --k8s-builder=true \
    --external-service-builder=false
}

registerOrdererUser() {
  local CA_ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"
  local ORG_MSP="$4"
  local ORDERER_SECRET="$ENROLL_SECRET"

  inputLog "registering orderer user for $ORG_MSP"
  kubectl hlf ca register \
    --name="$CA_ID" \
    --user=orderer \
    --secret="$ORDERER_SECRET" \
    --type=orderer \
    --enroll-id="$ENROLL_NAME" \
    --enroll-secret="$ENROLL_SECRET" \
    --mspid="$ORG_MSP"
}

deployOrderer() {
  local ORDERER_ID="$1"
  local ENROLL_SECRET="$2"
  local CA_ID="$3"
  local ORG_MSP="$4"

  kubectl hlf ordnode create \
    --image="$ORDERER_IMAGE" \
    --version="$ORDERER_VERSION" \
    --storage-class="$STORAGE_CLASS" \
    --enroll-id=orderer \
    --mspid="$ORG_MSP" \
    --enroll-pw="$ENROLL_SECRET" \
    --capacity=2Gi \
    --name="$ORDERER_ID" \
    --ca-name="$CA_ID.$NAMESPACE"
}

configFilePath() {
  echo "$CONFIG_DIR/config-$1.yaml"
}

enrollFilePath() {
  echo "$CONFIG_DIR/enroll-$1.yaml"
}

ensureIsEnrolled() {
  local ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"
  local CA_ID="$4"
  local ORG_MSP="$5"
  local ENROLL_FILE="$(enrollFilePath "$ID")"

  if [ -f "$ENROLL_FILE" ]; then
    inputLog "user $ENROLL_NAME already enrolled for $ID"
  else
    inputLog "enrolling user $ENROLL_NAME for $ID"

    kubectl hlf ca enroll \
      --name="$CA_ID" \
      --ca-name tlsca \
      --user="$ENROLL_NAME" \
      --secret="$ENROLL_SECRET" \
      --mspid "$ORG_MSP" \
      --output "$ENROLL_FILE"
  fi
}

addOrdererAdmin() {
  local ORDERER_ID="$1"
  local ENROLL_NAME="$2"
  local ENROLL_SECRET="$3"
  local CA_ID="$4"
  local ORG_MSP="$5"
  local CONFIG_FILE="$(configFilePath "$ORDERER_ID")"
  local ENROLL_FILE="$(enrollFilePath "$ORDERER_ID")"

  ensureIsEnrolled "$ORDERER_ID" "$ENROLL_NAME" "$ENROLL_SECRET" "$CA_ID" "$ORG_MSP"

  inputLog "adding user $ENROLL_NAME as admin for $ORDERER_ID"
  kubectl hlf inspect \
    -o "$ORG_MSP" \
    --output "$CONFIG_FILE"
  kubectl hlf utils adduser \
    --userPath="$ENROLL_FILE" \
    --config="$CONFIG_FILE" \
    --username="$ORDERER_ADMIN" \
    --mspid="$ORG_MSP"
}

waitForNode() {
  local NODE_ID="$1"
  local end=$'\e[0m'
  local darkGray=$'\e[90m'

  echo -n "${darkGray}  waiting for $NODE_ID...${end}"

  nodeStatus() {
    kubectl get pods -l release="$NODE_ID" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}'
  }

  while [[ "$(nodeStatus)" != "True" ]]; do
    sleep 2
    echo -n "${darkGray}.${end}"
  done

  echo
}

deployNodes() {
  printItalics "Deploying CAs" "U1F512"
  <% orgs.forEach((org) => { -%>
    deployCA "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "$<%= org.ca.caAdminNameVar %>" "$<%= org.ca.caAdminPassVar %>"
  <% }) -%>
  <% orgs.forEach((org) => { -%>
    waitForNode "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>"
  <% }) -%>

  printItalics "Deploying Orderers" "U1F527"
  <% orgs.forEach((org) => { -%>
    <% if(org.ordererGroups.length > 0) { -%>
      registerOrdererUser "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "$<%= org.ca.caAdminNameVar %>" "$<%= org.ca.caAdminPassVar %>" "<%= org.mspName %>"
    <% } -%>
  <% }) -%>
  <% ordererGroups.forEach((group) => { -%>
    <% group.orderers.forEach((orderer, i) => { -%>
      <% const org = orgs.find((org) => org.name === orderer.orgName) -%>
      deployOrderer "<%= orderer.orgName.toLowerCase() %>-<%= group.name %>-orderer<%= i %>" "$<%= org.ca.caAdminPassVar %>" "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "<%= org.mspName %>"
    <% }) -%>
  <% }) -%>
  <% ordererGroups.forEach((group) => { -%>
    <% group.orderers.forEach((orderer, i) => { -%>
      <% const org = orgs.find((org) => org.name === orderer.orgName) -%>
      waitForNode "<%= orderer.orgName.toLowerCase() %>-<%= group.name %>-orderer<%= i %>"
      addOrdererAdmin "<%= orderer.orgName.toLowerCase() %>-<%= group.name %>-orderer<%= i %>" "$<%= org.ca.caAdminNameVar %>" "$<%= org.ca.caAdminPassVar %>" "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "<%= org.mspName %>"
    <% }) -%>
  <% }) -%>

  printItalics "Deploying Peers" "U2699"
  <% orgs.forEach((org) => { -%>
    <% if (org.peers.length) { -%>
      registerPeerUser "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "$<%= org.ca.caAdminNameVar %>" "$<%= org.ca.caAdminPassVar %>" "<%= org.mspName %>"
#      registerAdminUser "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "$<%= org.ca.caAdminNameVar %>" "$<%= org.ca.caAdminPassVar %>" "<%= org.mspName %>"
    <% } -%>
    <% org.peers.forEach((peer) => { -%>
      deployPeer "<%= org.name.toLowerCase() %>-<%= peer.name %>" "$<%= org.ca.caAdminPassVar %>" "<%= peer.db.type.toLowerCase() %>" "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" "<%= org.mspName %>"
    <% }) -%>
  <% }) -%>
  <% orgs.forEach((org) => { -%>
    <% org.peers.forEach((peer) => { -%>
      waitForNode "<%= org.name.toLowerCase() %>-<%= peer.name %>"
    <% }) -%>
  <% }) -%>
}

joinChannelByOrderer() {
  local CHANNEL_NAME="$1"
  local ORDERER_ID="$2"
  local CA_ID="$3"
  local ENROLL_NAME="$4"
  local ENROLL_SECRET="$5"
  local ORG_MSP="$6"
  local ENROLL_FILE="$(enrollFilePath "$ORDERER_ID")"

  ensureIsEnrolled "$ORDERER_ID" "$ENROLL_NAME" "$ENROLL_SECRET" "$CA_ID" "$ORG_MSP"

  inputLog "joining channel $CHANNEL_NAME by $ORDERER_ID"
  kubectl hlf ordnode join \
    --block="$CONFIG_DIR/$CHANNEL_NAME.block" \
    --name="$ORDERER_ID" \
    --namespace="$NAMESPACE" \
    --identity="$ENROLL_FILE"
}

#joinChannelByPeer() {
#  local CHANNEL_NAME="$1"
#  local PEER_ID="$2"
#  local CA_ID="$3"
#  local ENROLL_NAME="$4"
#  local ENROLL_SECRET="$5"
#  local ORG_MSP="$6"
#  local ORDERER_MSP="$7"
#  local IS_ANCHOR_PEER="$8"
#  local CONFIG_FILE="$(configFilePath "$CHANNEL_NAME-$PEER_ID")"
#  local ENROLL_FILE="$(enrollFilePath "$PEER_ID")"
#
#  ensureIsEnrolled "$PEER_ID" "$ENROLL_NAME" "$ENROLL_SECRET" "$CA_ID" "$ORG_MSP"
#
#  inputLog "joining channel $CHANNEL_NAME by $PEER_ID"
#
#  kubectl hlf inspect \
#    --output "$CONFIG_FILE" \
#    -o "$ORG_MSP" \
#    -o "$ORDERER_MSP"
#
#  kubectl hlf utils adduser \
#    --userPath="$ENROLL_FILE" \
#    --config="$CONFIG_FILE" \
#    --username="$ENROLL_NAME" \
#    --mspid="$ORG_MSP"
#
#  kubectl hlf channel join \
#    --name="$CHANNEL_NAME" \
#    --config="$CONFIG_FILE" \
#    --user="$ENROLL_NAME" \
#    -p="$PEER_ID.$NAMESPACE"
#
#   if [[ "$IS_ANCHOR_PEER" = "true" ]]; then
#    inputLog "marking $PEER_PEER_ID as anchor peer"
#    kubectl hlf channel addanchorpeer \
#      --name="$CHANNEL_NAME" \
#      --config="$CONFIG_FILE" \
#      --user="$ENROLL_NAME" \
#      --peer="$PEER_ID.$NAMESPACE"
#  fi
#}

createPeerChannelConfig() {
  local CHANNEL_NAME="$1"
  local PEER_ID="$2"
  local CA_ID="$3"
  local ENROLL_NAME="$4"
  local ENROLL_SECRET="$5"
  local ORG_MSP="$6"
  local ORDERER_MSP="$7"
  local CONFIG_FILE="$(configFilePath "$CHANNEL_NAME-$PEER_ID")"
  local ENROLL_FILE="$(enrollFilePath "$PEER_ID")"

  ensureIsEnrolled "$PEER_ID" "$ENROLL_NAME" "$ENROLL_SECRET" "$CA_ID" "$ORG_MSP"

  inputLog "creating config for $CHANNEL_NAME by $PEER_ID"
   set -x

  kubectl hlf inspect \
    --output "$CONFIG_FILE" \
    -o "$ORG_MSP" \
    -o "$ORDERER_MSP"

  kubectl hlf utils adduser \
    --userPath="$ENROLL_FILE" \
    --config="$CONFIG_FILE" \
    --username="$ENROLL_NAME" \
    --mspid="$ORG_MSP"

#  kubectl hlf channel join \
#    --name="$CHANNEL_NAME" \
#    --config="$CONFIG_FILE" \
#    --user="$ENROLL_NAME" \
#    -p="$PEER_ID.$NAMESPACE"
#
#   if [[ "$IS_ANCHOR_PEER" = "true" ]]; then
#    inputLog "marking $PEER_PEER_ID as anchor peer"
#    kubectl hlf channel addanchorpeer \
#      --name="$CHANNEL_NAME" \
#      --config="$CONFIG_FILE" \
#      --user="$ENROLL_NAME" \
#      --peer="$PEER_ID.$NAMESPACE"
#  fi
}

installChannels() {
  <% channels.forEach((channel) => { -%>
    <% const ordererOrg = orgs.find((o) => o.name === channel.ordererHead.orgName) -%>
    printItalics "Creating '<%= channel.name %>'" "U1F4FA"
    PEER_ORG_SIGN_CERT=$(kubectl get fabriccas org1-ca -o=jsonpath='{.status.ca_cert}')
    PEER_ORG_TLS_CERT=$(kubectl get fabriccas org1-ca -o=jsonpath='{.status.tlsca_cert}')
    IDENT_8=$(printf "%8s" "")
    ORDERER_TLS_CERT=$(kubectl get fabriccas "<%= ordererOrg.name.toLowerCase() %>-<%= ordererOrg.ca.prefix %>" -o=jsonpath='{.status.tlsca_cert}' | sed -e "s/^/${IDENT_8}/" )
    ORDERER0_TLS_CERT=$(kubectl get fabricorderernodes <%= channel.ordererHead.orgName.toLowerCase() %>-<%= channel.ordererGroup.name %>-orderer0 -o=jsonpath='{.status.tlsCert}' | sed -e "s/^/${IDENT_8}/" )


    echo "apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricMainChannel
metadata:
  name: <%= channel.name %>
spec:
  name: <%= channel.name %>
  adminOrdererOrganizations:
    - mspID: OrdererMSP
  adminPeerOrganizations:
    - mspID: Org1MSP
  channelConfig:
    application:
      acls: null
      capabilities:
        - V2_0
      policies: null
    capabilities:
      - V2_0
    orderer:
      batchSize:
        absoluteMaxBytes: 1048576
        maxMessageCount: 10
        preferredMaxBytes: 524288
      batchTimeout: 2s
      capabilities:
        - V2_0
      etcdRaft:
        options:
          electionTick: 10
          heartbeatTick: 1
          maxInflightBlocks: 5
          snapshotIntervalSize: 16777216
          tickInterval: 500ms
      ordererType: etcdraft
      policies: null
      state: STATE_NORMAL
    policies: null
  externalOrdererOrganizations: []
  peerOrganizations:
    - mspID: Org1MSP
      caName: org1-ca
      caNamespace: default
  identities:
    OrdererMSP:
      secretKey: orderermsp.yaml
      secretName: wallet
      secretNamespace: default
    Org1MSP:
      secretKey: org1msp.yaml
      secretName: wallet
      secretNamespace: default
  externalPeerOrganizations: []
  ordererOrganizations:
    - caName: ord-ca
      caNamespace: default
      externalOrderersToJoin:
        - host: ord-node1
          port: 7053
      mspID: OrdererMSP
      ordererEndpoints:
        - ord-node1:7050
      orderersToJoin: []
  orderers:
    - host: ord-node1
      port: 7050
      tlsCert: |-
${ORDERER0_TLS_CERT}" | kubectl apply -f -
#    kubectl hlf channel generate <% -%>
#      --output="$CONFIG_DIR/<%= channel.name %>.block" <% -%>
#      --name="<%= channel.name %>" <% -%>
#      <% channel.orgs.forEach((org) => { -%> --organizations "<%= org.mspName %>" <% }) -%>
#      <% channel.ordererGroup.ordererHeads.forEach((cfg) => { -%> --ordererOrganizations "<%= cfg.orgMspName %>" <% }) -%>
#
#    <% channel.ordererGroup.orderers.forEach((orderer, i) => { -%>
#      <% const org = orgs.find((o) => o.name === orderer.orgName) -%>
#      joinChannelByOrderer <% -%>
#        "<%= channel.name %>" <% -%>
#        "<%= orderer.orgName.toLowerCase() %>-<%= channel.ordererGroup.name %>-orderer<%= i %>" <% -%>
#        "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" <% -%>
#        "$<%= org.ca.caAdminNameVar %>" <% -%>
#        "$<%= org.ca.caAdminPassVar %>" <% -%>
#        "<%= org.mspName %>"
#    <% }) -%>

    sleep 3
    <% channel.orgs.forEach((org) => { -%>
      echo "join channel by peer"

      # echo instead of EOF, since it is better handled by shellcheck
      echo "apiVersion: hlf.kungfusoftware.es/v1alpha1
kind: FabricFollowerChannel
metadata:
  name: <%= channel.name %>-org1msp
spec:
  anchorPeers:
    <%_ org.peers.forEach((peer) => { -%>
    - host: <%= org.name.toLowerCase() %>-<%= peer.name %>.default
      port: 7051
    <%_ }) -%>
  hlfIdentity:
    secretKey: org1msp.yaml
    secretName: wallet
    secretNamespace: default
  mspId: <%= org.mspName %>
  name: <%= channel.name %>
  externalPeersToJoin: []
  orderers:
    - certificate: |
${ORDERER0_TLS_CERT}
      url: grpcs://<%= channel.ordererHead.orgName.toLowerCase() %>-<%= channel.ordererGroup.name %>-orderer0.default:7050
  peersToJoin:
    <%_ org.peers.forEach((peer) => { -%>
    - name: <%= org.name.toLowerCase() %>-<%= peer.name %>
      namespace: default
    <%_ }) -%>
" | kubectl apply -f -
    <% }) -%>
  <% }) -%>
}

installChaincodes() {
  <% chaincodes.forEach((chaincode) => { -%>
    <% const orderer = chaincode.channel.ordererHead -%>
    printItalics "Installing chaincodes..." "U1F618"
    <% orgs.forEach((org) => { org.peers.forEach((peer) => { %>
      createPeerChannelConfig <% -%>
        "<%= chaincode.channel.name %>" <% -%>
        "<%= org.name.toLowerCase() %>-<%= peer.name %>" <% -%>
        "<%= org.name.toLowerCase() %>-<%= org.ca.prefix %>" <% -%>
        "$<%= org.ca.caAdminNameVar %>" <% -%>
        "$<%= org.ca.caAdminPassVar %>" <% -%>
        "<%= org.mspName %>" <% -%>
        "<%= orderer.orgMspName %>" <% -%>

      printItalics "Building chaincode <%= chaincode.name %>" "U1F618"
      CONFIG_FILE="$(configFilePath "<%= chaincode.channel.name %>-<%= org.name.toLowerCase() %>-<%= peer.name %>")"

      buildAndInstallChaincode <% -%>
        "<%= chaincode.name %>" <% -%>
        "<%= org.name.toLowerCase() %>-<%= peer.name %>.$NAMESPACE" <% -%>
        "<%= chaincode.lang %>" <% -%>
        "$CHAINCODES_BASE_DIR/<%= chaincode.directory %>" <% -%>
        "<%= chaincode.version %>" "$<%= org.ca.caAdminNameVar %>" <% -%>
        "$CONFIG_FILE"

      printItalics "Approving chaincode...." "U1F618"
      approveChaincode <% -%>
        "<%= chaincode.name %>" <% -%>
        "<%= org.name.toLowerCase() %>-<%= peer.name %>.$NAMESPACE" <% -%>
        "<%= chaincode.version %>" <% -%>
        "<%= chaincode.channel.name %>" <% -%>
        "$<%= org.ca.caAdminNameVar %>" <% -%>
        "$CONFIG_FILE" <% -%>
        "<%= org.mspName %>"

      printItalics "Committing chaincode '<%= chaincode.name %>' on channel '<%= chaincode.channel.name %>' " "U1F618"

      commitChaincode <% -%>
        "<%= chaincode.name %>" <% -%>
        "<%= org.name.toLowerCase() %>-<%= peer.name %>.$NAMESPACE" <% -%>
        "<%= chaincode.version %>" <% -%>
        "<%= chaincode.channel.name %>" <% -%>
        "$<%= org.ca.caAdminNameVar %>" <% -%>
        "$CONFIG_FILE" <% -%>
        "<%= org.mspName %>"
    <% })}) %>
  <% }) %>
}

destroyNetwork() {
  kubectl delete fabricpeers.hlf.kungfusoftware.es --all-namespaces --all
  kubectl delete fabriccas.hlf.kungfusoftware.es --all-namespaces --all
  kubectl delete fabricorderernodes.hlf.kungfusoftware.es --all-namespaces --all
  kubectl delete fabricchaincode.hlf.kungfusoftware.es --all-namespaces --all
}

printHeadline() {
  bold=$'\e[1m'
  end=$'\e[0m'

  TEXT=$1
  EMOJI=$2
  printf "${bold}============ %b %s %b ==============${end}\n" "\\$EMOJI" "$TEXT" "\\$EMOJI"
}

printItalics() {
  italics=$'\e[3m'
  end=$'\e[0m'

  TEXT=$1
  EMOJI=$2
  printf "${italics}==== %b %s %b ====${end}\n" "\\$EMOJI" "$TEXT" "\\$EMOJI"
}

inputLog() {
  end=$'\e[0m'
  darkGray=$'\e[90m'

  echo "${darkGray}  $1 ${end}"
}

inputLogShort() {
  end=$'\e[0m'
  darkGray=$'\e[90m'

  echo "${darkGray}  $1 ${end}"
}

verifyKubernetesConnectivity() {
  echo "Verifying kubectl-hlf installation..."
  if ! [[ $(command -v kubectl-hlf) ]]; then
    echo "Error: Fablo could not detect kubectl hlf plugin. Ensure you have installed:
  - kubectl - https://kubernetes.io/docs/tasks/tools/
  - helm - https://helm.sh/docs/intro/install/
  - krew - https://krew.sigs.k8s.io/docs/user-guide/setup/install/
  - hlf-operator along with krew hlf plugin - https://github.com/hyperledger-labs/hlf-operator#install-kubernetes-operator

Or try to call:
  helm install hlf-operator --version=1.8.2 kfs/hlf-operator && kubectl krew install hlf"
    exit 1
  else
    echo "  $(command -v kubectl-hlf)"
  fi

  if [ "$(kubectl get pods -l=app.kubernetes.io/name=hlf-operator -o jsonpath='{.items}')" = "[]" ]; then
    echo "Error: hlf-operator is not running. You can install it with:"
    echo "  helm install hlf-operator --version=1.8.2 kfs/hlf-operator"
    exit 1
  fi

  echo "Verifying default kubernetes cluster"
  if ! kubectl get ns default >/dev/null 2>&1; then
    printf "No K8 cluster detected\n" >&2
    exit 1
  fi

  while [ "$(kubectl get pods -l=app.kubernetes.io/name=hlf-operator -o jsonpath='{.items[*].status.containerStatuses[0].ready}')" != "true" ]; do
    sleep 5
    echo "$BLUE" "Waiting for Operator to be ready." "$RESETBG"
  done
}
