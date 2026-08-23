#!/usr/bin/env bash
# Runs AS ROOT on every control-plane node.
# HAProxy (VIP:PORT -> masters:6443) + Keepalived (floats the VIP).
# usage: lb-setup.sh <node-ip> <vip> <vip-port> <priority> <router-id> <auth-pass> <name:ip,name:ip,...>
set -euo pipefail

NODE_IP="$1"; VIP="$2"; VIP_PORT="$3"; PRIORITY="$4"; ROUTER_ID="$5"; AUTH_PASS="$6"; BACKENDS="$7"
export DEBIAN_FRONTEND=noninteractive
say() { echo "  [lb $NODE_IP] $*"; }
trap 'rc=$?; echo "  [lb $NODE_IP] ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc' ERR

IFACE="$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
[ -n "$IFACE" ] || { echo "ERROR: no interface holds $NODE_IP"; exit 1; }
say "VIP $VIP on $IFACE (priority $PRIORITY)"

apt-get update -qq
apt-get install -y -qq haproxy keepalived

# ---------------- HAProxy ----------------
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4000
    daemon

defaults
    mode                tcp
    log                 global
    option              tcplog
    option              dontlognull
    retries             3
    timeout connect     10s
    timeout client      1m
    timeout server      1m
    timeout check       5s

frontend kube-apiserver
    bind *:${VIP_PORT}
    mode tcp
    option tcplog
    default_backend kube-apiserver-backend

backend kube-apiserver-backend
    mode tcp
    balance roundrobin
    option tcp-check
EOF

IFS=',' read -ra ITEMS <<< "$BACKENDS"
for item in "${ITEMS[@]}"; do
  name="${item%%:*}"; ip="${item##*:}"
  echo "    server ${name} ${ip}:6443 check fall 3 rise 2 inter 2s" >> /etc/haproxy/haproxy.cfg
done

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
systemctl enable haproxy >/dev/null 2>&1 || true
systemctl restart haproxy

# ---------------- Keepalived ----------------
cat > /etc/keepalived/check_apiserver.sh <<EOF
#!/bin/sh
errorExit() { echo "\$*" 1>&2; exit 1; }
# HAProxy alive?
pidof haproxy >/dev/null || errorExit "haproxy is not running"
# Front-end answering locally?
nc -z -w2 127.0.0.1 ${VIP_PORT} || errorExit "port ${VIP_PORT} closed"
# If we currently hold the VIP, the VIP endpoint itself must work
if ip -4 -o addr show | grep -qw "${VIP}"; then
  nc -z -w2 ${VIP} ${VIP_PORT} || errorExit "VIP ${VIP}:${VIP_PORT} not answering"
fi
exit 0
EOF
chmod +x /etc/keepalived/check_apiserver.sh
apt-get install -y -qq netcat-openbsd >/dev/null 2>&1 || apt-get install -y -qq netcat >/dev/null 2>&1 || true

cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id LVS_K8S_${PRIORITY}
    script_user root
    enable_script_security
}

vrrp_script check_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_KUBE {
    state BACKUP
    interface ${IFACE}
    virtual_router_id ${ROUTER_ID}
    priority ${PRIORITY}
    advert_int 1
    nopreempt
    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/24 dev ${IFACE}
    }
    track_script {
        check_apiserver
    }
}
EOF

systemctl enable keepalived >/dev/null 2>&1 || true
systemctl restart keepalived
say "haproxy=$(systemctl is-active haproxy) keepalived=$(systemctl is-active keepalived)"
