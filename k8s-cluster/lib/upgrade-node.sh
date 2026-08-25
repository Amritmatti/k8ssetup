#!/usr/bin/env bash
# Runs AS ROOT on one node during a minor-version upgrade.
# usage: upgrade-node.sh <minor> <phase>
#   minor  target minor version, e.g. 1.34
#   phase  apply     -- first control-plane node: kubeadm + 'kubeadm upgrade apply'
#          node      -- every other node:         kubeadm + 'kubeadm upgrade node'
#          kubelet   -- kubelet/kubectl packages + restart (run while drained)
#          downgrade -- WORKERS ONLY: put kubeadm/kubelet/kubectl back on an
#                       older minor (kubeadm cannot downgrade a control plane)
set -euo pipefail

MINOR="$1"
PHASE="$2"
HOST="$(hostname)"
export DEBIAN_FRONTEND=noninteractive
say() { echo "  [$HOST] $*"; }
trap 'rc=$?; echo "  [$HOST] ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit $rc' ERR

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
  apt_get update -qq
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
    apt_mark unhold kubeadm >/dev/null 2>&1 || true
    apt_get install -y -qq --allow-change-held-packages "kubeadm=${PKG}"
    apt_mark hold kubeadm >/dev/null
    say "kubeadm is now $(kubeadm version -o short)"

    if [ "$PHASE" = apply ]; then
      say "kubeadm upgrade apply v${PKG%%-*}  (control plane, etcd, CoreDNS)"
      kubeadm upgrade apply -y "v${PKG%%-*}"
    else
      say "kubeadm upgrade node"
      kubeadm upgrade node
    fi
    ;;

  downgrade)
    # Worker rollback: put the apt repo back on the older minor and install the
    # whole trio at that version. Only valid for workers -- kubeadm does not
    # support downgrading a control-plane node.
    repo_switch
    PKG="$(pkg_version)"
    [ -n "$PKG" ] || { echo "no packages for ${MINOR}.x in the repo" >&2; exit 1; }
    say "downgrading kubeadm/kubelet/kubectl to ${PKG}"
    apt_mark unhold kubeadm kubelet kubectl >/dev/null 2>&1 || true
    apt_get install -y -qq --allow-change-held-packages --allow-downgrades \
      "kubeadm=${PKG}" "kubelet=${PKG}" "kubectl=${PKG}"
    apt_mark hold kubeadm kubelet kubectl >/dev/null
    systemctl daemon-reload
    systemctl restart kubelet
    say "kubelet restarted: $(kubelet --version)"
    ;;

  kubelet)
    PKG="$(pkg_version)"
    [ -n "$PKG" ] || { echo "no kubelet package for ${MINOR}.x in the repo" >&2; exit 1; }
    say "installing kubelet/kubectl ${PKG}"
    apt_mark unhold kubelet kubectl >/dev/null 2>&1 || true
    apt_get install -y -qq --allow-change-held-packages "kubelet=${PKG}" "kubectl=${PKG}"
    apt_mark hold kubelet kubectl >/dev/null
    systemctl daemon-reload
    systemctl restart kubelet
    say "kubelet restarted: $(kubelet --version)"
    ;;

  *) echo "unknown phase '$PHASE' (apply|node|kubelet|downgrade)" >&2; exit 1 ;;
esac
