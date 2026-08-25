#!/usr/bin/env bash
# Runs AS ROOT on every control-plane node.
# HAProxy (VIP:PORT -> masters:6443) + Keepalived (floats the VIP).
# usage: lb-setup.sh <node-ip> <vip> <vip-port> <priority> <router-id> <auth-pass> <name:ip,name:ip,...>
set -euo pipefail

NODE_IP="$1"; VIP="$2"; VIP_PORT="$3"; PRIORITY="$4"; ROUTER_ID="$5"; AUTH_PASS="$6"; BACKENDS="$7"
export DEBIAN_FRONTEND=noninteractive
say() { echo "  [lb $NODE_IP] $*"; }
trap 'rc=$?; echo "  [lb $NODE_IP] ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc' ERR

# --- apt, on a machine that is still updating itself ----------------------
# unattended-upgrades holds the dpkg lock and kills any apt-get that lands in
# its window; wait for the lock rather than racing it. The long version of
# this comment, and the same helper, live in node-prep.sh -- each of these
# scripts is copied to a node and run on its own, so it carries its own copy.
APT_LOCK_WAIT="${APT_LOCK_WAIT:-600}"    # seconds apt waits on a held lock
APT_TRIES="${APT_TRIES:-5}"              # attempts before we give up on it
APT_RETRY_WAIT="${APT_RETRY_WAIT:-30}"   # pause between them

# Name the process sitting on the lock, so the wait is explainable.
apt_lock_holder() {
  local f p out=""
  command -v fuser >/dev/null || { printf ' another process'; return 0; }
  for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
    for p in $(fuser "$f" 2>/dev/null || true); do
      out="$out $(cat "/proc/$p/comm" 2>/dev/null || echo '?')($p)"
    done
  done
  printf '%s' "${out:- another process}"
}

# Only a held lock is worth coming back for: a package that will not install
# fails the same way five minutes from now, so let it fail at once.
apt_run() {   # <apt-get|apt-mark> <args...>
  local bin="$1"; shift
  local out try=1 rc=0
  out="$(mktemp)"
  while :; do
    rc=0
    "$bin" -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" "$@" >"$out" 2>&1 || rc=$?
    cat "$out"
    if [ "$rc" -eq 0 ] || [ "$try" -ge "$APT_TRIES" ]        || ! grep -qE 'Could not get lock|Unable to acquire' "$out"; then
      rm -f "$out"; return "$rc"
    fi
    say "apt is locked by$(apt_lock_holder) -- retry $try/$APT_TRIES in ${APT_RETRY_WAIT}s"
    sleep "$APT_RETRY_WAIT"; try=$((try + 1))
  done
}
apt_get()  { apt_run apt-get  "$@"; }
apt_mark() { apt_run apt-mark "$@"; }

IFACE="$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
[ -n "$IFACE" ] || { echo "ERROR: no interface holds $NODE_IP"; exit 1; }
say "VIP $VIP on $IFACE (priority $PRIORITY)"

apt_get update -qq
apt_get install -y -qq haproxy keepalived

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
apt_get install -y -qq netcat-openbsd >/dev/null 2>&1 || apt_get install -y -qq netcat >/dev/null 2>&1 || true

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
