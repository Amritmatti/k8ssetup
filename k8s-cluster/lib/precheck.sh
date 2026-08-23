#!/usr/bin/env bash
# Runs AS ROOT on a candidate node. Prints KEY=VALUE facts for deploy.sh.
# Reaching this point at all proves ssh + sudo work.
set -uo pipefail

. /etc/os-release 2>/dev/null || true
echo "OS=${ID:-unknown}-${VERSION_ID:-?}"
echo "ARCH=$(uname -m)"
echo "CPUS=$(nproc)"
echo "MEM=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
echo "DISK=$(df -Pm / | awk 'NR==2{print $4}')"
echo "ADDRS=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | paste -sd, -)"
echo "SWAP=$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
echo "K8S=$(command -v kubeadm >/dev/null && kubeadm version -o short 2>/dev/null || echo none)"
echo "INIT=$(test -f /etc/kubernetes/admin.conf && echo yes || echo no)"
echo "PRECHECK=OK"
