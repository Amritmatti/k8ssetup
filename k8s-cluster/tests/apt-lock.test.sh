#!/usr/bin/env bash
# Regression test for the dpkg-lock race that killed 'prepare node' on one
# node at a time: unattended-upgrades holds /var/lib/dpkg/lock-frontend and
# whichever apt-get lands in that window exits 100.
#
# Runs anywhere bash does -- apt-get is stubbed, nothing is installed.
#   usage: tests/apt-lock.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

say() { echo "  [test] $*"; }          # the helper reports through say()
export APT_RETRY_WAIT=0 APT_TRIES=5 PATH="$WORK/bin:$PATH"

pass=0; fail=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS $1"; pass=$((pass + 1))
  else echo "  FAIL $1 (want '$3', got '$2')"; fail=$((fail + 1)); fi
}

# An apt-get that fails the first <n> calls exactly as the real one did on
# master-2, then installs. 'broken' instead fails for a reason no amount of
# waiting fixes.
mk_stub() {  # <lock-failures> [broken]
  cat > "$WORK/bin/apt-get" <<STUB
#!/usr/bin/env bash
n=\$(cat "$WORK/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$WORK/calls"
echo "\$*" >> "$WORK/argv"
if [ "${2:-lock}" = broken ]; then
  echo "E: Unable to locate package bogus-package" >&2; exit 100
fi
if [ "\$n" -le $1 ]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 3106 (unattended-upgr)" >&2
  echo "E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?" >&2
  exit 100
fi
echo "Setting up kubelet (1.33.13-1.1) ..."; exit 0
STUB
  chmod +x "$WORK/bin/apt-get"; rm -f "$WORK/calls" "$WORK/argv"
}

# The helper exactly as it ships inside node-prep.sh -- read from the script
# itself, so a copy that drifts fails here.
eval "$(sed -n '/^# --- apt, on a machine/,/^apt_mark()/p' "$REPO/lib/node-prep.sh")"

echo "== a single lock collision is what killed the node prep"
mk_stub 1
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null 2>&1
check "bare apt-get dies with exit 100" "$?" "100"

echo "== apt_get waits the upgrade out and installs"
mk_stub 2
out="$(apt_get install -y -qq kubelet kubeadm kubectl 2>&1)"; rc=$?
check "succeeds"                     "$rc" "0"
check "after 3 attempts"             "$(cat "$WORK/calls")" "3"
check "installed for real"           "$(grep -c 'Setting up kubelet' <<<"$out")" "1"
check "said why it waited"           "$(grep -c 'apt is locked' <<<"$out")" "2"
check "asked apt to wait too"        "$(grep -c 'DPkg::Lock::Timeout=600' "$WORK/argv")" "3"

echo "== a lock that never frees fails; it does not hang forever"
mk_stub 99
apt_get install -y -qq kubelet >/dev/null 2>&1
check "gives up with apt's status"   "$?" "100"
check "after APT_TRIES attempts"     "$(cat "$WORK/calls")" "5"

echo "== a package that cannot install fails at once, without the retries"
mk_stub 0 broken
apt_get install -y -qq bogus-package >/dev/null 2>&1
check "fails with exit 100"          "$?" "100"
check "on the first attempt"         "$(cat "$WORK/calls")" "1"

echo "== every script that installs packages carries the helper"
for f in node-prep.sh lb-setup.sh upgrade-node.sh; do
  check "$f defines apt_get" \
    "$(grep -c '^apt_get()  { apt_run apt-get  "\$@"; }' "$REPO/lib/$f")" "1"
  # every call site goes through the wrapper; only its own definition and
  # the sanity probe may name apt-get directly
  check "$f has no bare apt-get" \
    "$(grep -E '^[^#]*[^_]apt-(get|mark) ' "$REPO/lib/$f" | grep -Evc 'apt_run|command -v')" "0"
done

echo; echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
