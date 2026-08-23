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
swapoff -a || true
sed -i.bak -E 's|^([^#].*\sswap\s)|#\1|' /etc/fstab
systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
  [ -n "$u" ] && systemctl --now mask "$u" >/dev/null 2>&1 || true
done
systemctl --now disable systemd-zram-setup@zram0.service >/dev/null 2>&1 || true

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
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg socat conntrack ethtool

# --- containerd -----------------------------------------------------------
if ! command -v containerd >/dev/null; then
  say "installing containerd"
  apt-get install -y -qq containerd
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
  apt-get update -qq
  apt-get install -y -qq kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl >/dev/null
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
