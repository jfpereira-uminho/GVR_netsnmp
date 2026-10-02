#!/usr/bin/env bash
#
# GVR SNMP lab - build and deploy an SNMP agent and an SNMP manager in two
# containers, each in its own network namespace, connected by a veth pair:
#
#   +---------------------------+            +---------------------------+
#   | container "manager"       |            | container "agent"         |
#   | netns #2                  |    veth    | netns #1                  |
#   | eth0 10.0.0.2/30  <-------+------------+-------> eth0 10.0.0.1/30  |
#   | snmptrapd (udp/162)       |            | snmpd (udp/161)           |
#   | snmpget, snmpwalk, ...    |            |                           |
#   +---------------------------+            +---------------------------+
#
# Usage: ./lab.sh {build|up|down|status|logs <c>|shell <c>}
#
# Set DOCKER=podman to force podman (default: docker).
#
set -euo pipefail

DOCKER=${DOCKER:-docker}

AGENT=agent
MANAGER=manager
AGENT_IMG=gvr-snmp-agent
MANAGER_IMG=gvr-snmp-manager
AGENT_IP=10.0.0.1
MANAGER_IP=10.0.0.2
PREFIX=30
IFNAME=eth0

cd "$(dirname "$0")"

log() { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[lab]\033[0m %s\n' "$*" >&2; exit 1; }

running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

cmd_build() {
    log "building $AGENT_IMG"
    $DOCKER build -t "$AGENT_IMG" -f agent/Dockerfile .
    log "building $MANAGER_IMG"
    $DOCKER build -t "$MANAGER_IMG" -f manager/Dockerfile .
}

start_container() { # <name> <image>
    # --network none: the container gets a fresh network namespace that
    # contains only 'lo'. We plug the veth ourselves afterwards.
    $DOCKER run -d --name "$1" --hostname "$1" \
        --network none \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        "$2" >/dev/null
}

wire() {
    local pa pm
    pa=$($DOCKER inspect -f '{{.State.Pid}}' "$AGENT")
    pm=$($DOCKER inspect -f '{{.State.Pid}}' "$MANAGER")
    log "network namespaces: agent pid=$pa, manager pid=$pm"

    # A short-lived privileged helper sees the host PID namespace, enters
    # each container's network namespace with nsenter and runs ip(8):
    #   1. create the veth pair inside the agent netns and push the peer
    #      end straight into the manager netns
    #   2. assign addresses and bring the links up
    $DOCKER run --rm --privileged --pid host --network none \
        --entrypoint sh "$MANAGER_IMG" -c "
        set -e
        nsenter -t $pa -n ip link add $IFNAME type veth peer name $IFNAME netns $pm
        nsenter -t $pa -n ip addr add $AGENT_IP/$PREFIX dev $IFNAME
        nsenter -t $pa -n ip link set lo up
        nsenter -t $pa -n ip link set $IFNAME up
        nsenter -t $pm -n ip addr add $MANAGER_IP/$PREFIX dev $IFNAME
        nsenter -t $pm -n ip link set lo up
        nsenter -t $pm -n ip link set $IFNAME up
    "

    # Name resolution between the two containers
    $DOCKER exec "$AGENT"   sh -c "echo '$MANAGER_IP $MANAGER' >> /etc/hosts"
    $DOCKER exec "$MANAGER" sh -c "echo '$AGENT_IP $AGENT' >> /etc/hosts"
    log "veth up: $AGENT ($AGENT_IP) <---> $MANAGER ($MANAGER_IP)"
}

cmd_up() {
    for c in "$AGENT" "$MANAGER"; do
        if $DOCKER inspect "$c" >/dev/null 2>&1; then
            die "container '$c' already exists - run './lab.sh down' first"
        fi
    done
    $DOCKER image inspect "$AGENT_IMG" >/dev/null 2>&1 &&
        $DOCKER image inspect "$MANAGER_IMG" >/dev/null 2>&1 ||
        die "images not found - run './lab.sh build' first"

    # Manager first: snmptrapd must be listening before the agent's
    # coldStart trap is sent.
    log "starting $MANAGER"
    start_container "$MANAGER" "$MANAGER_IMG"
    log "starting $AGENT"
    start_container "$AGENT" "$AGENT_IMG"
    wire

    log "waiting for snmpd ..."
    for _ in $(seq 1 20); do
        if $DOCKER exec "$MANAGER" snmpget -v2c -c public -t 1 -r 0 \
                "$AGENT" SNMPv2-MIB::sysUpTime.0 >/dev/null 2>&1; then
            log "lab is up. Try:"
            echo "    $DOCKER exec -it $MANAGER sh"
            echo "    snmpwalk -v2c -c public $AGENT system"
            return 0
        fi
        sleep 1
    done
    die "snmpd did not answer - check '$DOCKER logs $AGENT'"
}

cmd_down() {
    for c in "$AGENT" "$MANAGER"; do
        if $DOCKER inspect "$c" >/dev/null 2>&1; then
            log "removing $c"
            $DOCKER rm -f "$c" >/dev/null
        fi
    done
    # The veth pair is destroyed together with the network namespaces.
}

cmd_status() {
    for c in "$AGENT" "$MANAGER"; do
        if running "$c"; then
            echo "== $c (running) =="
            $DOCKER exec "$c" ip -br addr
        else
            echo "== $c (not running) =="
        fi
    done
}

case "${1:-}" in
    build)  cmd_build ;;
    up)     cmd_up ;;
    down)   cmd_down ;;
    restart) cmd_down; cmd_up ;;
    status) cmd_status ;;
    logs)   $DOCKER logs -f "${2:?usage: $0 logs agent|manager}" ;;
    shell)  $DOCKER exec -it "${2:?usage: $0 shell agent|manager}" sh ;;
    *)
        echo "usage: $0 {build|up|down|restart|status|logs <c>|shell <c>}"
        exit 1 ;;
esac
