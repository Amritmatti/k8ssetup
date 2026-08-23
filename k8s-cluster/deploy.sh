#!/usr/bin/env bash
# =============================================================================
#  deploy.sh -- multi-master / multi-worker Kubernetes on VirtualBox VMs
#
#    ./deploy.sh preflight              check every VM before touching it
#    ./deploy.sh deploy                 build the whole cluster   (default)
#    ./deploy.sh add worker-4 IP [k=v]  add a brand-new node
#    ./deploy.sh add worker-2           re-add a node listed in cluster.conf
#    ./deploy.sh status                 nodes / unhealthy pods / etcd / VIP
#    ./deploy.sh kubeconfig             re-fetch the admin kubeconfig
#    ./deploy.sh reset [label]          tear down every node, or just one
#
#  Everything is driven by cluster.conf -- you only edit IPs and labels there.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/cluster.conf}"
LOG_DIR="$SCRIPT_DIR/logs"
STAGE_DIR="$SCRIPT_DIR/.stage"

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=; fi
log()  { printf '%s==>%s %s\n'   "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n'  "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%sFAIL%s %s\n'  "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s--- %s %s%s\n' "$C_B" "$*" "$(printf '%.0s-' $(seq 1 40))" "$C_0"; }

# ---------------------------------------------------------------- config ----
[ -f "$CONFIG" ] || die "config not found: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"

: "${SSH_USER:=vagrant}"; : "${SSH_PORT:=22}"; : "${SSH_KEY:=}"
: "${SSH_PASSWORD:=}";    : "${SUDO_PASSWORD:=}"
: "${VIP:=}"; : "${VIP_PORT:=8443}"; : "${VIP_HOSTNAME:=k8s-api}"
: "${VRRP_ROUTER_ID:=51}"; : "${VRRP_AUTH_PASS:=k8sHAvip}"
: "${K8S_VERSION:=1.33}"; : "${POD_CIDR:=10.244.0.0/16}"; : "${SERVICE_CIDR:=10.96.0.0/12}"
: "${CNI:=calico}"; : "${CALICO_VERSION:=v3.28.2}"; : "${FLANNEL_VERSION:=v0.25.7}"
: "${CNI_IFACE_DETECT:=auto}"; : "${KUBECONFIG_OUT:=$SCRIPT_DIR/kubeconfig}"

NAMES=(); IPS=(); ROLES=(); XLABELS=()
MASTER_NAMES=(); MASTER_IPS=(); WORKER_NAMES=(); WORKER_IPS=()

parse_nodes() {
  local entry name ip labels role dup
  for entry in "${NODES[@]}"; do
    entry="$(echo "$entry" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')"
    [ -z "$entry" ] && continue
    name="$(cut -d' ' -f1 <<<"$entry")"
    ip="$(cut -d' ' -f2 <<<"$entry")"
    labels="$(cut -d' ' -f3- -s <<<"$entry")"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "bad IP for '$name': '$ip'"
    case "$name" in
      master-*|master|control-*|controlplane-*|cp-*) role=master ;;
      worker-*|worker|node-*)                        role=worker ;;
      *) die "cannot derive a role from label '$name' -- use master-N / worker-N" ;;
    esac
    NAMES+=("$name"); IPS+=("$ip"); ROLES+=("$role"); XLABELS+=("$labels")
    if [ "$role" = master ]; then MASTER_NAMES+=("$name"); MASTER_IPS+=("$ip")
    else WORKER_NAMES+=("$name"); WORKER_IPS+=("$ip"); fi
  done
  [ "${#MASTER_NAMES[@]}" -gt 0 ] || die "no master nodes defined in $CONFIG"
  dup="$(printf '%s\n' "${IPS[@]}"   | sort | uniq -d)"; [ -z "$dup" ] || die "duplicate IP(s): $dup"
  dup="$(printf '%s\n' "${NAMES[@]}" | sort | uniq -d)"; [ -z "$dup" ] || die "duplicate label(s): $dup"

  FIRST_MASTER_NAME="${MASTER_NAMES[0]}"
  FIRST_MASTER_IP="${MASTER_IPS[0]}"
  if [ -n "$VIP" ]; then
    CP_ENDPOINT="${VIP}:${VIP_PORT}"; USE_LB=yes
    if printf '%s\n' "${IPS[@]}" | grep -qx "$VIP"; then die "VIP $VIP must not be one of the node IPs"; fi
    # The VIP is an extra address on the nodes' own NIC -- it MUST share their subnet,
    # otherwise only the master holding it can reach it and every join times out.
    local vip_net node_net
    vip_net="${VIP%.*}"; node_net="${FIRST_MASTER_IP%.*}"
    if [ "$vip_net" != "$node_net" ]; then
      die "VIP $VIP is not on the node subnet (${node_net}.0/24, e.g. $FIRST_MASTER_IP).
       Pick a free address such as ${node_net}.179 -- outside your DHCP pool."
    fi
    for ip in "${IPS[@]}"; do
      [ "${ip%.*}" = "$node_net" ] || warn "$ip is not on ${node_net}.0/24 -- the VIP can only serve one subnet"
    done
  else
    CP_ENDPOINT="${FIRST_MASTER_IP}:6443"; USE_LB=no
    [ "${#MASTER_IPS[@]}" -le 1 ] || die "a multi-master cluster needs VIP set in $CONFIG"
  fi
  [ "$CNI_IFACE_DETECT" = auto ] && CNI_IFACE_DETECT="can-reach=${FIRST_MASTER_IP}"
  return 0
}

ip_of() { local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$1" ] && { echo "${IPS[$i]}"; return 0; }; done; return 1; }
idx_of() { local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }

# ------------------------------------------------------------------- ssh ----
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o LogLevel=ERROR -o ServerAliveInterval=30)

_ssh() {
  local ip="$1"; shift
  if [ -n "$SSH_PASSWORD" ]; then
    sshpass -p "$SSH_PASSWORD" ssh "${SSH_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} -p "$SSH_PORT" "${SSH_USER}@${ip}" "$@"
  else
    ssh "${SSH_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} -p "$SSH_PORT" "${SSH_USER}@${ip}" "$@"
  fi
}

_scp() {
  local src="$1" ip="$2" dst="$3"
  if [ -n "$SSH_PASSWORD" ]; then
    sshpass -p "$SSH_PASSWORD" scp "${SSH_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} -P "$SSH_PORT" -q "$src" "${SSH_USER}@${ip}:${dst}"
  else
    scp "${SSH_OPTS[@]}" ${SSH_KEY:+-i "$SSH_KEY"} -P "$SSH_PORT" -q "$src" "${SSH_USER}@${ip}:${dst}"
  fi
}

sudo_prefix() {
  if [ "$SSH_USER" = root ]; then printf ''
  elif [ -n "$SUDO_PASSWORD" ]; then printf 'echo %q | sudo -S -p "" ' "$SUDO_PASSWORD"
  else printf 'sudo -n '; fi
}

# copy a local script to a node and run it as root; remote stdout comes back
run_script() {
  local ip="$1" lf="$2"; shift 2
  local rf="/tmp/k8sdeploy-$(basename "$lf")" argstr="" a rc=0
  _scp "$lf" "$ip" "$rf" || return 1
  for a in "$@"; do argstr+="$(printf '%q ' "$a")"; done
  _ssh "$ip" "chmod +x '$rf'; $(sudo_prefix)bash '$rf' $argstr; rc=\$?; rm -f '$rf'; exit \$rc" || rc=$?
  return $rc
}

# run an inline shell snippet as root on a node
rroot() {
  local ip="$1"; shift
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/k8sd-inline.XXXXXX")"
  { echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo 'trap '"'"'rc=$?; echo "remote ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc'"'"' ERR'
    printf '%s\n' "$*"; } > "$tmp"
  run_script "$ip" "$tmp" || rc=$?
  rm -f "$tmp"
  return $rc
}

# kubectl on the first master, using the cluster admin config
kctl() { rroot "$FIRST_MASTER_IP" "export KUBECONFIG=/etc/kubernetes/admin.conf; $*"; }

# =============================================================== preflight ==
cmd_preflight() {
  step "preflight"
  command -v ssh >/dev/null && command -v scp >/dev/null || die "ssh/scp client not found"
  if [ -n "$SSH_PASSWORD" ]; then command -v sshpass >/dev/null || die "SSH_PASSWORD is set but 'sshpass' is not installed"; fi
  if [ -n "$SSH_KEY" ]; then [ -f "$SSH_KEY" ] || die "SSH_KEY not found: $SSH_KEY"; fi

  local i fail=0 out os cpus mem disk addrs msg
  printf '  %-10s %-16s %-7s %s\n' NODE IP ROLE RESULT
  for i in "${!NAMES[@]}"; do
    if ! out="$(run_script "${IPS[$i]}" "$SCRIPT_DIR/lib/precheck.sh" 2>&1)" || ! grep -q '^PRECHECK=OK' <<<"$out"; then
      printf '  %-10s %-16s %-7s %sunreachable / sudo failed: %s%s\n' \
        "${NAMES[$i]}" "${IPS[$i]}" "${ROLES[$i]}" "$C_R" "$(tail -1 <<<"$out")" "$C_0"
      fail=1; continue
    fi
    os="$(sed -n 's/^OS=//p'    <<<"$out")"
    cpus="$(sed -n 's/^CPUS=//p' <<<"$out")"
    mem="$(sed -n 's/^MEM=//p'  <<<"$out")"
    disk="$(sed -n 's/^DISK=//p' <<<"$out")"
    addrs="$(sed -n 's/^ADDRS=//p' <<<"$out")"
    msg=""
    grep -qiE 'ubuntu|debian' <<<"$os" || { msg+="unsupported OS ($os); "; fail=1; }
    grep -qx "${IPS[$i]}" <<<"$(tr ',' '\n' <<<"$addrs")" || { msg+="IP not present on this VM (has: $addrs); "; fail=1; }
    if [ "${ROLES[$i]}" = master ] && [ "${cpus:-0}" -lt 2 ]; then msg+="masters need >=2 vCPU (has $cpus); "; fail=1; fi
    [ "${mem:-0}"  -lt 1700 ] && msg+="low RAM ${mem}MB; "
    [ "${disk:-0}" -lt 8000 ] && msg+="low free disk ${disk}MB; "
    if [ -z "$msg" ]; then
      printf '  %-10s %-16s %-7s %sok%s  %s\n' "${NAMES[$i]}" "${IPS[$i]}" "${ROLES[$i]}" "$C_G" "$C_0" "$C_D$os ${cpus}cpu ${mem}MB$C_0"
    else
      printf '  %-10s %-16s %-7s %s%s%s\n' "${NAMES[$i]}" "${IPS[$i]}" "${ROLES[$i]}" "$C_Y" "$msg" "$C_0"
    fi
  done

  if [ "$USE_LB" = yes ] && [ "$fail" -eq 0 ]; then
    if rroot "$FIRST_MASTER_IP" "ping -c1 -W1 $VIP >/dev/null 2>&1 && echo INUSE || echo FREE" | grep -q INUSE; then
      warn "VIP $VIP already answers ping (fine when re-running; otherwise pick a free address)"
    else
      ok "VIP $VIP is free"
    fi
  fi
  [ "$fail" -eq 0 ] || die "preflight failed -- fix the items above and re-run"
  ok "preflight passed"
}

# ============================================================== node prep ===
gen_hosts_file() {
  mkdir -p "$STAGE_DIR"
  {
    echo "# BEGIN K8S-CLUSTER"
    local i
    for i in "${!NAMES[@]}"; do printf '%s %s\n' "${IPS[$i]}" "${NAMES[$i]}"; done
    [ -n "$VIP" ] && printf '%s %s\n' "$VIP" "$VIP_HOSTNAME"
    echo "# END K8S-CLUSTER"
  } > "$STAGE_DIR/k8s-hosts"
}

prep_node() {  # <name> <ip>
  local name="$1" ip="$2"
  _scp "$STAGE_DIR/k8s-hosts" "$ip" /tmp/k8s-hosts
  run_script "$ip" "$SCRIPT_DIR/lib/node-prep.sh" "$name" "$ip" "$K8S_VERSION" /tmp/k8s-hosts
}

prep_all() {
  step "preparing all nodes (swap/sysctl/containerd/kubeadm) in parallel"
  mkdir -p "$LOG_DIR"; gen_hosts_file
  local i j rc=0 pids=() names=()
  for i in "${!NAMES[@]}"; do
    ( prep_node "${NAMES[$i]}" "${IPS[$i]}" ) > "$LOG_DIR/prep-${NAMES[$i]}.log" 2>&1 &
    pids+=("$!"); names+=("${NAMES[$i]}")
    printf '  %-10s %-16s %sworking...%s\n' "${NAMES[$i]}" "${IPS[$i]}" "$C_D" "$C_0"
  done
  for j in "${!pids[@]}"; do
    if wait "${pids[$j]}"; then ok "${names[$j]} ready"
    else
      err "${names[$j]} failed -- full log: $LOG_DIR/prep-${names[$j]}.log"
      tail -n 15 "$LOG_DIR/prep-${names[$j]}.log" >&2; rc=1
    fi
  done
  [ "$rc" -eq 0 ] || die "node preparation failed"
}

# ==================================================== load balancer / VIP ===
setup_lb() {
  if [ "$USE_LB" != yes ]; then log "single master, no VIP configured -- skipping HAProxy/Keepalived"; return 0; fi
  step "HAProxy + Keepalived on the control plane (VIP ${VIP}:${VIP_PORT})"
  local i n backends="" prio=200
  for i in "${!MASTER_NAMES[@]}"; do backends+="${MASTER_NAMES[$i]}:${MASTER_IPS[$i]},"; done
  backends="${backends%,}"
  for i in "${!MASTER_NAMES[@]}"; do
    run_script "${MASTER_IPS[$i]}" "$SCRIPT_DIR/lib/lb-setup.sh" \
        "${MASTER_IPS[$i]}" "$VIP" "$VIP_PORT" "$prio" "$VRRP_ROUTER_ID" "$VRRP_AUTH_PASS" "$backends" \
      || die "load balancer setup failed on ${MASTER_NAMES[$i]}"
    prio=$((prio - 10))
  done
  # Probe from a node that does NOT hold the VIP -- pinging it from the holder
  # always succeeds and would hide a wrong-subnet or promiscuous-mode problem.
  local prober prober_name
  if   [ "${#WORKER_IPS[@]}" -gt 0 ]; then prober="${WORKER_IPS[0]}";  prober_name="${WORKER_NAMES[0]}"
  elif [ "${#MASTER_IPS[@]}" -gt 1 ]; then prober="${MASTER_IPS[1]}";  prober_name="${MASTER_NAMES[1]}"
  else prober="$FIRST_MASTER_IP"; prober_name="$FIRST_MASTER_NAME"; fi

  log "waiting for the VIP to answer from $prober_name"
  for n in $(seq 1 30); do
    if rroot "$prober" "ping -c1 -W1 $VIP >/dev/null 2>&1 && echo UP || echo DOWN" | grep -q UP; then
      ok "VIP $VIP is live and reachable from $prober_name"; return 0
    fi
    sleep 2
  done
  die "VIP $VIP is not reachable from $prober_name. Check, in this order:
       1. $VIP is on the same subnet as the nodes (${FIRST_MASTER_IP%.*}.0/24)
       2. 'systemctl status keepalived' on the masters, and 'ip -4 addr' to see who holds it
       3. promiscuous mode = 'Allow All' on the masters' cluster NIC in VirtualBox"
}

# Refuse to start joining until the advertised endpoint actually works from
# another VM -- this is what turns a silent 'kubeadm join' timeout into a
# one-line explanation.
verify_endpoint() {
  [ "$USE_LB" = yes ] || return 0
  step "verifying the control-plane endpoint ${CP_ENDPOINT}"
  local prober prober_name n
  if   [ "${#WORKER_IPS[@]}" -gt 0 ]; then prober="${WORKER_IPS[0]}";  prober_name="${WORKER_NAMES[0]}"
  elif [ "${#MASTER_IPS[@]}" -gt 1 ]; then prober="${MASTER_IPS[1]}";  prober_name="${MASTER_NAMES[1]}"
  else return 0; fi
  for n in $(seq 1 20); do
    if rroot "$prober" "curl -sk --max-time 5 https://${CP_ENDPOINT}/healthz 2>/dev/null | grep -q ok && echo REACHABLE || echo NO" | grep -q REACHABLE; then
      ok "https://${CP_ENDPOINT}/healthz answers from $prober_name"
      return 0
    fi
    sleep 3
  done
  die "the API is up on $FIRST_MASTER_NAME but https://${CP_ENDPOINT} is unreachable from $prober_name.
       Every join and every kubelet uses that address, so fix it before continuing:
         - is $VIP on ${FIRST_MASTER_IP%.*}.0/24, the same subnet as the nodes?
         - 'systemctl status haproxy' on the VIP holder, and 'ss -lntp | grep $VIP_PORT'
         - 'journalctl -u keepalived -n 30' on all masters"
}

# ============================================================ first master ==
kubeadm_api_version() {
  local minor="${K8S_VERSION#*.}"; minor="${minor%%.*}"
  if [ "${minor:-0}" -ge 31 ]; then echo "kubeadm.k8s.io/v1beta4"; else echo "kubeadm.k8s.io/v1beta3"; fi
}

init_first_master() {
  step "kubeadm init on $FIRST_MASTER_NAME ($FIRST_MASTER_IP)"
  if rroot "$FIRST_MASTER_IP" "test -f /etc/kubernetes/admin.conf && echo EXISTS || echo NEW" | grep -q EXISTS; then
    warn "$FIRST_MASTER_NAME is already initialised -- skipping kubeadm init"
    return 0
  fi
  local i kver api sans
  kver="$(rroot "$FIRST_MASTER_IP" 'kubeadm version -o short' | tr -d '\r' | tail -1)"
  api="$(kubeadm_api_version)"
  sans=""
  for i in "${!MASTER_IPS[@]}"; do sans+="  - \"${MASTER_IPS[$i]}\"\n  - \"${MASTER_NAMES[$i]}\"\n"; done
  [ -n "$VIP" ] && sans+="  - \"${VIP}\"\n  - \"${VIP_HOSTNAME}\"\n"
  sans+="  - \"127.0.0.1\"\n  - \"localhost\"\n"

  mkdir -p "$STAGE_DIR"
  {
    cat <<EOF
apiVersion: ${api}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${FIRST_MASTER_IP}
  bindPort: 6443
nodeRegistration:
  name: ${FIRST_MASTER_NAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: ${api}
kind: ClusterConfiguration
kubernetesVersion: ${kver}
clusterName: vbox-k8s
controlPlaneEndpoint: "${CP_ENDPOINT}"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
EOF
    printf '%b' "$sans"
    cat <<EOF
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  } > "$STAGE_DIR/kubeadm-init.yaml"

  _scp "$STAGE_DIR/kubeadm-init.yaml" "$FIRST_MASTER_IP" /tmp/kubeadm-init.yaml
  rroot "$FIRST_MASTER_IP" "
kubeadm init --config /tmp/kubeadm-init.yaml --upload-certs
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
" || die "kubeadm init failed on $FIRST_MASTER_NAME (see the output above)"
  setup_user_kubeconfig "$FIRST_MASTER_IP"
  ok "control plane bootstrapped -- endpoint https://${CP_ENDPOINT}"
}

setup_user_kubeconfig() {   # give the SSH user a working kubectl on that node
  local ip="$1"
  [ "$SSH_USER" = root ] && return 0
  rroot "$ip" "
install -d -m 750 -o $SSH_USER -g $SSH_USER /home/$SSH_USER/.kube
install -m 600 -o $SSH_USER -g $SSH_USER /etc/kubernetes/admin.conf /home/$SSH_USER/.kube/config
" >/dev/null || warn "could not install kubeconfig for user $SSH_USER on $ip"
  return 0
}

# ===================================================================== CNI ==
install_cni() {
  step "installing CNI: $CNI"
  if kctl "kubectl get ds -A -o name 2>/dev/null || true" | grep -qE 'calico-node|kube-flannel'; then
    warn "a CNI daemonset is already installed -- skipping"
  else
    case "$CNI" in
      calico)
        rroot "$FIRST_MASTER_IP" "
export KUBECONFIG=/etc/kubernetes/admin.conf
curl -fsSL -o /tmp/calico.yaml https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' /tmp/calico.yaml
sed -i 's|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|' /tmp/calico.yaml
kubectl apply -f /tmp/calico.yaml
kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=${CNI_IFACE_DETECT}
" || die "calico install failed"
        ;;
      flannel)
        rroot "$FIRST_MASTER_IP" "
export KUBECONFIG=/etc/kubernetes/admin.conf
curl -fsSL -o /tmp/flannel.yaml https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml
sed -i 's|10.244.0.0/16|${POD_CIDR}|g' /tmp/flannel.yaml
sed -i 's|- --kube-subnet-mgr|- --kube-subnet-mgr\n        - --iface-can-reach=${FIRST_MASTER_IP}|' /tmp/flannel.yaml
kubectl apply -f /tmp/flannel.yaml
" || die "flannel install failed"
        ;;
      *) die "unknown CNI '$CNI' -- use calico or flannel" ;;
    esac
  fi
  log "waiting for $FIRST_MASTER_NAME to report Ready"
  kctl "kubectl wait --for=condition=Ready node/$FIRST_MASTER_NAME --timeout=300s" \
    || die "$FIRST_MASTER_NAME never became Ready -- check 'kubectl -n kube-system get pods'"
  ok "CNI is up"
}

# =================================================================== joins ==
join_info() {   # refresh JOIN_CMD + CERT_KEY (both are short-lived)
  JOIN_CMD="$(kctl "kubeadm token create --print-join-command 2>/dev/null" | tr -d '\r' | grep '^kubeadm join' | tail -1)"
  [ -n "$JOIN_CMD" ] || die "could not generate a join command on $FIRST_MASTER_NAME"
  CERT_KEY="$(kctl "kubeadm init phase upload-certs --upload-certs 2>/dev/null" | tr -d '\r' | grep -E '^[a-f0-9]{32,}$' | tail -1)"
}

node_joined() { kctl "kubectl get node $1 --no-headers 2>/dev/null || true" | grep -q "^$1[[:space:]]"; }

join_master() { # <name> <ip>
  local name="$1" ip="$2"
  if node_joined "$name"; then warn "$name is already a cluster member -- skipping"; return 0; fi
  [ -n "$CERT_KEY" ] || die "no certificate key available for the control-plane join"
  log "joining control-plane node $name ($ip)"
  rroot "$ip" "$JOIN_CMD --control-plane --certificate-key $CERT_KEY --apiserver-advertise-address $ip --node-name $name" \
    || die "control-plane join failed on $name"
  setup_user_kubeconfig "$ip"
  kctl "kubectl wait --for=condition=Ready node/$name --timeout=300s" >/dev/null 2>&1 || warn "$name joined but is not Ready yet"
  ok "$name joined the control plane"
}

join_worker() { # <name> <ip>
  local name="$1" ip="$2"
  if node_joined "$name"; then warn "$name is already a cluster member -- skipping"; return 0; fi
  log "joining worker $name ($ip)"
  rroot "$ip" "$JOIN_CMD --node-name $name" || die "worker join failed on $name"
  ok "$name joined"
}

join_all() {
  local i j rc=0 pids=() names=()
  if [ "${#MASTER_NAMES[@]}" -gt 1 ]; then
    step "joining the remaining control-plane nodes (one at a time, for etcd quorum)"
    for i in "${!MASTER_NAMES[@]}"; do
      [ "$i" -eq 0 ] && continue
      join_info
      join_master "${MASTER_NAMES[$i]}" "${MASTER_IPS[$i]}"
    done
  fi
  if [ "${#WORKER_NAMES[@]}" -gt 0 ]; then
    step "joining workers (in parallel)"
    join_info
    mkdir -p "$LOG_DIR"
    for i in "${!WORKER_NAMES[@]}"; do
      ( join_worker "${WORKER_NAMES[$i]}" "${WORKER_IPS[$i]}" ) > "$LOG_DIR/join-${WORKER_NAMES[$i]}.log" 2>&1 &
      pids+=("$!"); names+=("${WORKER_NAMES[$i]}")
    done
    for j in "${!pids[@]}"; do
      if wait "${pids[$j]}"; then ok "${names[$j]} joined"
      else
        err "${names[$j]} failed -- full log: $LOG_DIR/join-${names[$j]}.log"
        tail -n 15 "$LOG_DIR/join-${names[$j]}.log" >&2; rc=1
      fi
    done
    [ "$rc" -eq 0 ] || die "one or more workers failed to join"
  fi
}

apply_labels() {
  step "labelling nodes"
  local i
  for i in "${!NAMES[@]}"; do
    node_joined "${NAMES[$i]}" || continue
    if [ "${ROLES[$i]}" = worker ]; then
      kctl "kubectl label node ${NAMES[$i]} node-role.kubernetes.io/worker=worker --overwrite" >/dev/null \
        || warn "could not set the worker role label on ${NAMES[$i]}"
    fi
    if [ -n "${XLABELS[$i]}" ]; then
      kctl "kubectl label node ${NAMES[$i]} $(tr ',' ' ' <<<"${XLABELS[$i]}") --overwrite" >/dev/null \
        || warn "could not apply extra labels to ${NAMES[$i]}"
    fi
  done
  ok "labels applied"
}

# ============================================================= kubeconfig ===
cmd_kubeconfig() {
  local out="$KUBECONFIG_OUT"
  case "$out" in /*) ;; *) out="$SCRIPT_DIR/${out#./}" ;; esac
  rroot "$FIRST_MASTER_IP" "cat /etc/kubernetes/admin.conf" | tr -d '\r' > "$out"
  grep -q 'kind: Config' "$out" || die "failed to fetch the kubeconfig from $FIRST_MASTER_NAME"
  chmod 600 "$out" 2>/dev/null || true
  ok "kubeconfig written to $out (server https://${CP_ENDPOINT})"
}

# ================================================================= status ===
cmd_status() {
  step "cluster status"
  kctl "kubectl get nodes -o wide --show-labels=false" || die "cannot reach the API server"
  echo
  log "pods that are not Running/Completed"
  kctl "kubectl get pods -A -o wide | awk 'NR==1 || (\$4!=\"Running\" && \$4!=\"Completed\")'" || true
  echo
  log "etcd members"
  kctl "P=\$(kubectl -n kube-system get pods -l component=etcd -o name | head -1 | cut -d/ -f2); \
        kubectl -n kube-system exec \$P -- etcdctl \
          --endpoints=https://127.0.0.1:2379 \
          --cacert=/etc/kubernetes/pki/etcd/ca.crt \
          --cert=/etc/kubernetes/pki/etcd/server.crt \
          --key=/etc/kubernetes/pki/etcd/server.key member list -w table" 2>/dev/null \
    || warn "could not query etcd"
  if [ "$USE_LB" = yes ]; then
    echo; local i
    for i in "${!MASTER_NAMES[@]}"; do
      if rroot "${MASTER_IPS[$i]}" "ip -4 -o addr show | grep -qw $VIP && echo HOLDS || echo NO" | grep -q HOLDS; then
        ok "VIP $VIP is currently held by ${MASTER_NAMES[$i]}"
      fi
    done
  fi
}

# ==================================================================== add ===
cmd_add() {
  local name="${1:-}" ip="${2:-}" labels="${3:-}" role i idx known=no
  [ -n "$name" ] || die "usage: $0 add <label> [ip] [k=v,k=v]"

  if idx="$(idx_of "$name")"; then
    # Already described in cluster.conf -- this is a re-add after 'reset <label>'.
    # Reuse its IP and labels instead of appending a duplicate entry.
    known=yes
    [ -n "$ip" ] || ip="${IPS[$idx]}"
    [ "$ip" = "${IPS[$idx]}" ] || die "$name is ${IPS[$idx]} in $CONFIG, not $ip -- edit the config instead"
    [ -n "$labels" ] || labels="${XLABELS[$idx]}"
    role="${ROLES[$idx]}"
  else
    [ -n "$ip" ] || die "$name is not in $CONFIG -- usage: $0 add <label> <ip> [k=v,k=v]"
    case "$name" in master-*|control-*|cp-*) role=master ;; *) role=worker ;; esac
    NAMES+=("$name"); IPS+=("$ip"); ROLES+=("$role"); XLABELS+=("$labels")
    if [ "$role" = master ]; then MASTER_NAMES+=("$name"); MASTER_IPS+=("$ip"); fi
  fi

  if [ "$known" = yes ]; then step "re-adding $role $name ($ip)"
  else step "adding $role $name ($ip)"; fi
  gen_hosts_file
  for i in "${!NAMES[@]}"; do   # refresh /etc/hosts everywhere
    _scp "$STAGE_DIR/k8s-hosts" "${IPS[$i]}" /tmp/k8s-hosts >/dev/null 2>&1 || continue
    rroot "${IPS[$i]}" "sed -i '/# BEGIN K8S-CLUSTER/,/# END K8S-CLUSTER/d' /etc/hosts; cat /tmp/k8s-hosts >> /etc/hosts" >/dev/null || true
  done
  prep_node "$name" "$ip" || die "preparation failed on $name"
  join_info
  if [ "$role" = master ]; then
    [ "$USE_LB" = yes ] || die "adding a master requires an HA endpoint (set VIP in $CONFIG)"
    join_master "$name" "$ip"
    log "re-rendering HAProxy so every master knows about the new backend"
    setup_lb
  else
    join_worker "$name" "$ip"
  fi
  [ "$known" = yes ] || warn "add \"$name  $ip\" to NODES in $CONFIG so future runs keep it"
  apply_labels
  cmd_status
}

# ================================================================== reset ===
cmd_reset() {
  local only="${1:-}" i tip answer
  local targets_n=() targets_i=()
  if [ -n "$only" ]; then
    tip="$(ip_of "$only")" || die "unknown node label: $only"
    targets_n=("$only"); targets_i=("$tip")
  else
    for i in "${!WORKER_NAMES[@]}"; do targets_n+=("${WORKER_NAMES[$i]}"); targets_i+=("${WORKER_IPS[$i]}"); done
    for ((i=${#MASTER_NAMES[@]}-1; i>=0; i--)); do targets_n+=("${MASTER_NAMES[$i]}"); targets_i+=("${MASTER_IPS[$i]}"); done
  fi
  step "RESET -- ${targets_n[*]}"
  if [ "${FORCE:-no}" != yes ]; then
    [ -t 0 ] || die "not a terminal: re-run with FORCE=yes to confirm the reset"
    read -r -p "  This destroys Kubernetes on the VMs above. Type 'yes' to continue: " answer
    [ "$answer" = yes ] || { log "aborted"; return 0; }
  fi
  for i in "${!targets_n[@]}"; do
    log "resetting ${targets_n[$i]}"
    if [ -n "$only" ]; then
      kctl "kubectl drain $only --ignore-daemonsets --delete-emptydir-data --force --timeout=120s" >/dev/null 2>&1 || true
      kctl "kubectl delete node $only" >/dev/null 2>&1 || true
    fi
    rroot "${targets_i[$i]}" "
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock >/dev/null 2>&1 || true
systemctl stop kubelet haproxy keepalived >/dev/null 2>&1 || true
systemctl disable haproxy keepalived >/dev/null 2>&1 || true
rm -rf /etc/cni/net.d /var/lib/cni /var/lib/etcd /etc/kubernetes /root/.kube /home/*/.kube || true
rm -f /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf /etc/keepalived/check_apiserver.sh || true
for l in cni0 flannel.1 vxlan.calico kube-ipvs0 dummy0; do ip link delete \$l >/dev/null 2>&1 || true; done
iptables -F >/dev/null 2>&1 || true; iptables -t nat -F >/dev/null 2>&1 || true
iptables -t mangle -F >/dev/null 2>&1 || true; iptables -X >/dev/null 2>&1 || true
command -v ipvsadm >/dev/null 2>&1 && ipvsadm -C >/dev/null 2>&1 || true
exit 0
" >/dev/null 2>&1 || warn "reset reported errors on ${targets_n[$i]}"
    ok "${targets_n[$i]} reset"
  done
  if [ -z "$only" ]; then
    # Drop generated artifacts too -- a stale kubeadm-init.yaml from a bad run is
    # confusing to find later, even though every deploy regenerates it.
    rm -f "$KUBECONFIG_OUT" 2>/dev/null || true
    rm -rf "$STAGE_DIR" 2>/dev/null || true
    ok "removed $KUBECONFIG_OUT and .stage/"
  fi
}

# ================================================================= deploy ===
cmd_deploy() {
  local t0=$SECONDS
  printf '  cluster : %s master(s) / %s worker(s)\n' "${#MASTER_NAMES[@]}" "${#WORKER_NAMES[@]}"
  printf '  endpoint: https://%s\n' "$CP_ENDPOINT"
  printf '  k8s     : v%s.x   cni=%s   pods=%s   svc=%s\n' "$K8S_VERSION" "$CNI" "$POD_CIDR" "$SERVICE_CIDR"
  cmd_preflight
  prep_all
  setup_lb
  init_first_master
  verify_endpoint
  install_cni
  join_all
  apply_labels
  cmd_kubeconfig
  cmd_status
  step "finished in $((SECONDS - t0))s"
  cat <<EOF

  From this machine:
      export KUBECONFIG=${KUBECONFIG_OUT}
      kubectl get nodes -o wide

  From any master:
      ssh ${SSH_USER}@${FIRST_MASTER_IP} kubectl get nodes

  HA test: power off ${FIRST_MASTER_NAME}, then run 'kubectl get nodes' again --
  keepalived moves ${VIP:-the endpoint} to the next master and the API keeps serving.
EOF
}

# print the header comment block, stopping at the first non-comment line
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# =================================================================== main ===
parse_nodes
case "${1:-deploy}" in
  deploy|"")  cmd_deploy ;;
  preflight)  cmd_preflight ;;
  prep)       prep_all ;;
  lb)         setup_lb ;;
  add)        shift; cmd_add "$@" ;;
  status)     cmd_status ;;
  kubeconfig) cmd_kubeconfig ;;
  reset)      shift; cmd_reset "${1:-}" ;;
  -h|--help|help) usage ;;
  *) err "unknown command: $1"; usage; exit 1 ;;
esac
