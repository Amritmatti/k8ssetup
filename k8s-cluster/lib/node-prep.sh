#!/usr/bin/env bash
# Runs AS ROOT on every cluster node (masters + workers).
# usage: node-prep.sh <node-name> <node-ip> <k8s-minor-version> <hosts-file>
set -euo pipefail

NODE_NAME="$1"
NODE_IP="$2"
K8S_VERSION="$3"
HOSTS_FILE="${4:-/tmp/k8s-hosts}"

export DEBIAN_FRONTEND=noninteractive
say() { echo "  [$NODE_NAME] $*"; }

# Never fail silently: report the exact line and command that died.
trap 'rc=$?; echo "  [$NODE_NAME] ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc' ERR

# --- apt, on a machine that is still updating itself ----------------------
# Ubuntu runs unattended-upgrades a few minutes into every boot, and it holds
# the dpkg frontend lock for as long as its work takes. An apt-get that lands
# in that window dies on the spot with "Could not get lock
# /var/lib/dpkg/lock-frontend" - and because the nodes are prepared in
# parallel, it kills whichever node drew the short straw, a different one
# each run. That reads as a broken VM rather than the race it is.
#
# So wait for the lock instead of racing it. apt does the waiting itself;
# the retry is for the apt too old to know that option, and for the upgrade
# that takes the lock back in the gap between two of our calls.
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

# --- sanity ---------------------------------------------------------------
command -v apt-get >/dev/null || { echo "ERROR: only Debian/Ubuntu supported"; exit 1; }
ip -4 -o addr show | grep -qw "$NODE_IP" || {
  echo "ERROR: $NODE_IP is not configured on this VM"; ip -4 -o addr show; exit 1; }

# --- hostname + /etc/hosts ------------------------------------------------
say "hostname -> $NODE_NAME"
hostnamectl set-hostname "$NODE_NAME"
sed -i '/^127\.0\.1\.1/d' /etc/hosts
sed -i '/# BEGIN K8S-CLUSTER/,/# END K8S-CLUSTER/d' /etc/hosts
cat "$HOSTS_FILE" >> /etc/hosts

# --- swap off -------------------------------------------------------------
say "disabling swap"
swapoff -a >/dev/null 2>&1 || true
if [ -f /etc/fstab ]; then sed -i.bak -E 's|^([^#].*[[:space:]]swap[[:space:]])|#\1|' /etc/fstab; fi
# systemctl exits non-zero when nothing matches, so absorb it before pipefail sees it
SWAP_UNITS="$(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}' || true)"
for u in $SWAP_UNITS; do systemctl --now mask "$u" >/dev/null 2>&1 || true; done
systemctl --now disable systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
if [ "$(awk '/^SwapTotal/{print $2}' /proc/meminfo)" != "0" ]; then
  say "WARN: swap is still active -- 'swapon --show' on this VM"
fi

# --- firewall (lab clusters: get it out of the way) -----------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "disabling ufw"; ufw --force disable
fi

# --- kernel modules + sysctl ---------------------------------------------
say "kernel modules + sysctl"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay; modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

# --- base packages --------------------------------------------------------
say "apt update + base packages"
apt_get update -qq
apt_get install -y -qq apt-transport-https ca-certificates curl gnupg socat conntrack ethtool

# --- containerd -----------------------------------------------------------
if ! command -v containerd >/dev/null; then
  say "installing containerd"
  apt_get install -y -qq containerd
fi
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ] || ! grep -q SystemdCgroup /etc/containerd/config.toml; then
  containerd config default > /etc/containerd/config.toml
fi
sed -i 's/^\( *\)SystemdCgroup *= *false/\1SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# --- kubeadm / kubelet / kubectl -----------------------------------------
if ! command -v kubeadm >/dev/null; then
  say "installing kubeadm/kubelet/kubectl (v${K8S_VERSION})"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt_get update -qq
  apt_get install -y -qq kubelet kubeadm kubectl
  apt_mark hold kubelet kubeadm kubectl >/dev/null
fi

# --- pin kubelet to the right NIC (critical on multi-NIC VirtualBox VMs) --
say "kubelet --node-ip=$NODE_IP"
mkdir -p /etc/default
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--node-ip=${NODE_IP}"
EOF

# --- keep containerd's pause image in sync with kubeadm's -----------------
PAUSE="$(kubeadm config images list 2>/dev/null | grep -m1 '/pause:' || true)"
if [ -n "$PAUSE" ]; then
  sed -i -E "s|sandbox_image = \".*\"|sandbox_image = \"${PAUSE}\"|" /etc/containerd/config.toml
  sed -i -E "s|^( *)sandbox = \".*/pause:.*\"|\1sandbox = \"${PAUSE}\"|" /etc/containerd/config.toml
  systemctl restart containerd
fi

systemctl enable kubelet >/dev/null 2>&1 || true
kubeadm config images pull >/dev/null 2>&1 || say "WARN: image pre-pull failed (continuing)"

say "prepared: $(kubeadm version -o short)"
