#!/usr/bin/env bash
# Runs AS ROOT on the first master. Prints machine-readable facts about cluster
# health and upgrade risk, so the orchestrator can gate on them.
#   usage: cluster-health.sh [health|risk]
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
MODE="${1:-health}"

ETCD_FLAGS="--endpoints=https://127.0.0.1:2379
  --cacert=/etc/kubernetes/pki/etcd/ca.crt
  --cert=/etc/kubernetes/pki/etcd/server.crt
  --key=/etc/kubernetes/pki/etcd/server.key"

etcd_pod() { kubectl -n kube-system get pods -l component=etcd -o name 2>/dev/null | head -1 | cut -d/ -f2; }

case "$MODE" in
health)
  echo "NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{printf "%s ", $1}')"
  echo "BADPODS=$(kubectl get pods -A --no-headers 2>/dev/null \
      | awk '$4!="Running" && $4!="Completed"{printf "%s/%s ", $1,$2}')"
  echo "UNAVAILABLE=$(kubectl get deploy -A --no-headers 2>/dev/null \
      | awk '{split($3,r,"/"); if (r[1]+0 < r[2]+0) printf "%s/%s ", $1,$2}')"
  P="$(etcd_pod)"
  if [ -n "$P" ]; then
    # shellcheck disable=SC2086
    H="$(kubectl -n kube-system exec "$P" -- etcdctl $ETCD_FLAGS endpoint health --cluster 2>&1 || true)"
    echo "ETCD_MEMBERS=$(grep -c 'is healthy\|is unhealthy' <<<"$H")"
    echo "ETCD_HEALTHY=$(grep -c 'is healthy' <<<"$H")"
  else
    echo "ETCD_MEMBERS=0"; echo "ETCD_HEALTHY=0"
  fi
  echo "HEALTH=OK"
  ;;

risk)
  # Workloads that cannot survive a node drain without a gap in service:
  # a single replica has nowhere to fail over to.
  kubectl get deploy,statefulset -A --no-headers -o custom-columns=\
'NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name,R:.spec.replicas' 2>/dev/null \
    | awk '$4+0 < 2 && $1 != "kube-system" {print "SINGLE=" $1 "/" tolower($2) "/" $3}'

  # A PodDisruptionBudget is what makes 'kubectl drain' wait instead of evicting
  # every replica at once. Namespaces running workloads without one are exposed.
  for ns in $(kubectl get deploy,statefulset -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do
    [ "$ns" = "kube-system" ] && continue
    n="$(kubectl -n "$ns" get pdb --no-headers 2>/dev/null | wc -l)"
    [ "$n" -eq 0 ] && echo "NOPDB=$ns"
  done

  # CoreDNS is the one kube-system workload whose disruption every pod notices.
  echo "COREDNS=$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  echo "PDBS=$(kubectl get pdb -A --no-headers 2>/dev/null | wc -l)"
  echo "RISK=OK"
  ;;

*) echo "unknown mode '$MODE'" >&2; exit 1 ;;
esac
