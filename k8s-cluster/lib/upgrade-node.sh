#!/usr/bin/env bash
# Runs AS ROOT on one node during a minor-version upgrade.
# usage: upgrade-node.sh <minor> <phase>
#   minor  target minor version, e.g. 1.34
#   phase  apply   -- first control-plane node: kubeadm + 'kubeadm upgrade apply'
#          node    -- every other node:         kubeadm + 'kubeadm upgrade node'
#          kubelet -- kubelet/kubectl packages + restart (run while drained)
set -euo pipefail

MINOR="$1"
PHASE="$2"
HOST="$(hostname)"
export DEBIAN_FRONTEND=noninteractive
say() { echo "  [$HOST] $*"; }
trap 'rc=$?; echo "  [$HOST] ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc' ERR

# The apt repository is per-minor-version -- pointing it at the new minor is the
# step that is easiest to forget, and without it every package stays on the old
# series and 'kubeadm upgrade' has nothing to install.
repo_switch() {
  local list=/etc/apt/sources.list.d/kubernetes.list
  if ! grep -q "v${MINOR}/deb" "$list" 2>/dev/null; then
    say "switching apt repo to v${MINOR}"
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/Release.key" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/ /" > "$list"
  fi
  apt-get update -qq
}

# Newest patch release available for the target minor, e.g. 1.34.1-1.1
pkg_version() {
  local esc="${MINOR//./\\.}"
  apt-cache madison kubeadm 2>/dev/null | awk '{print $3}' | grep -m1 "^${esc}\." || true
}

case "$PHASE" in
  apply|node)
    repo_switch
    PKG="$(pkg_version)"
    [ -n "$PKG" ] || { echo "no kubeadm package for ${MINOR}.x in the repo" >&2; exit 1; }
    say "installing kubeadm ${PKG}"
    apt-mark unhold kubeadm >/dev/null 2>&1 || true
    apt-get install -y -qq --allow-change-held-packages "kubeadm=${PKG}"
    apt-mark hold kubeadm >/dev/null
    say "kubeadm is now $(kubeadm version -o short)"

    if [ "$PHASE" = apply ]; then
      say "kubeadm upgrade apply v${PKG%%-*}  (control plane, etcd, CoreDNS)"
      kubeadm upgrade apply -y "v${PKG%%-*}"
    else
      say "kubeadm upgrade node"
      kubeadm upgrade node
    fi
    ;;

  kubelet)
    PKG="$(pkg_version)"
    [ -n "$PKG" ] || { echo "no kubelet package for ${MINOR}.x in the repo" >&2; exit 1; }
    say "installing kubelet/kubectl ${PKG}"
    apt-mark unhold kubelet kubectl >/dev/null 2>&1 || true
    apt-get install -y -qq --allow-change-held-packages "kubelet=${PKG}" "kubectl=${PKG}"
    apt-mark hold kubelet kubectl >/dev/null
    systemctl daemon-reload
    systemctl restart kubelet
    say "kubelet restarted: $(kubelet --version)"
    ;;

  *) echo "unknown phase '$PHASE' (apply|node|kubelet)" >&2; exit 1 ;;
esac
