# Multi-master Kubernetes on VirtualBox VMs

Bash-only kubeadm installer. You edit one file (`cluster.conf`) with labels and IPs,
run `./deploy.sh`, and get a working HA cluster: stacked-etcd control plane behind a
Keepalived VIP, containerd, Calico (or Flannel), and labelled workers.

```
k8s-cluster/
├── cluster.conf         <-- the only file you edit: labels + IPs
├── deploy.sh            <-- orchestrator (runs on your workstation)
├── Vagrantfile          <-- OPTIONAL: creates the VirtualBox VMs
└── lib/
    ├── precheck.sh      runs on each VM: facts for preflight
    ├── node-prep.sh     runs on each VM: swap/sysctl/containerd/kubeadm
    └── lb-setup.sh      runs on each master: HAProxy + Keepalived (the VIP)
```

## Resource requirements

### Per VM

| | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| **Master (hard floor)** | **2** | **2 GB** | 10 GB | kubeadm aborts below 2 CPU; below 2 GB the control plane OOMs during init |
| Master (comfortable) | 2 | 2.5–3 GB | 15 GB | what the bundled `Vagrantfile` sets (2 vCPU / 2560 MB) |
| **Worker (hard floor)** | **1** | **1 GB** | 10 GB | works, but leaves only ~300 MB for your pods |
| Worker (comfortable) | 2 | 2 GB | 15 GB | room for real workloads |

Idle consumption once the cluster settles: **~1.3–1.6 GB** on a master (etcd, apiserver,
controller-manager, scheduler, calico-node, kube-proxy) and **~600–800 MB** on a worker.

What `./deploy.sh preflight` checks: masters with `< 2 vCPU` are a **hard failure**;
`< 1700 MB` RAM or `< 8 GB` free disk on any node is a **warning** and the deploy continues.

### Host totals

| Layout | VMs | RAM for VMs | Host RAM incl. OS | Disk |
|---|---|---|---|---|
| 3 masters + 3 workers (the shipped `cluster.conf`) | 6 | ~15 GB | **20 GB** (16 GB is tight) | 60–90 GB |
| **3 masters + 2 workers** — smallest real HA cluster | 5 | ~10 GB | **16 GB** | ~50 GB |
| 3 masters + 1 worker | 4 | ~8 GB | **12 GB** | ~40 GB |
| 1 master + 2 workers (`VIP=""`) — no HA | 3 | ~5 GB | **8 GB** | ~30 GB |

CPU can be oversubscribed: 6 VMs × 2 vCPU on a 4-core/8-thread host is fine, just slower
during the parallel `apt` phase. Never give a single VM more vCPUs than the host has
physical cores.

Disks are thin-provisioned (dynamic VDI) — the Ubuntu box is ~2.5 GB and a node grows to
~6–8 GB once container images are pulled, so a 20 GB virtual disk costs ~8 GB of real space.

### If you are short on RAM

* Drop to **3 masters + 2 workers**, and untaint the masters so they run pods too:
  `kubectl taint nodes --all node-role.kubernetes.io/control-plane-`
* Set `CNI="flannel"` — saves ~150 MB per node versus Calico (Felix is the heavy part).
* Workers at 1 vCPU / 1536 MB and masters at 2048 MB is a workable floor.

Keep **3** masters, not 2. etcd quorum is `(n/2)+1`, so a two-member cluster stops serving
when either master dies — strictly worse than a single master. That is why `deploy.sh`
refuses a multi-master config that has no `VIP`.

## 1. Prepare the VMs

Six VMs (3 masters, 3 workers) of Ubuntu 22.04/24.04 or Debian 12, each with:

* Enough CPU/RAM/disk — see [Resource requirements](#resource-requirements) above
* **Two network adapters**: NAT (internet) + **Bridged** onto your LAN (cluster traffic).
  The bridged address is what goes into `cluster.conf` — never `10.0.2.15`, which every
  NAT adapter shares.
* An SSH user with **passwordless sudo** (Vagrant's `vagrant` user already has it),
  and your public key in `~/.ssh/authorized_keys`.
* **Promiscuous mode = Allow All** on the masters' bridged adapter, so the Keepalived
  VIP can float between them. VirtualBox otherwise drops the VIP's ARP replies.

No VMs yet? `vagrant up` with the bundled `Vagrantfile` builds all six.

### Network layout

Everything lives on one flat `192.168.1.0/24` LAN:

| Address | Role |
|---|---|
| `192.168.1.179` | **VIP** — the HA control-plane endpoint (`https://192.168.1.179:8443`) |
| `192.168.1.180-182` | masters |
| `192.168.1.183-185` | workers |
| `10.244.0.0/16` | pod network (internal — must not overlap your LAN) |
| `10.96.0.0/12` | service network (internal) |

Two rules that will bite you otherwise:

1. **The VIP must be on the same subnet as the nodes.** It is an extra address on the
   nodes' own NIC, so a VIP on a different network is reachable only by the master
   holding it — every join then times out. `deploy.sh` now refuses such a config up front.
2. **All seven addresses must be outside your router's DHCP pool.** These are static;
   a DHCP lease handed to another device on `.179` silently breaks the control plane.
   Check with `ping -c2 192.168.1.179` (no reply) before deploying, or reserve the
   `.176-.191` block in your router.

## 2. Describe the cluster

```bash
NODES=(
  "master-1  192.168.1.180"
  "master-2  192.168.1.181"
  "master-3  192.168.1.182"
  "worker-1  192.168.1.183"
  "worker-2  192.168.1.184"
  "worker-3  192.168.1.185   disk=ssd,zone=lab"   # optional extra labels
)
VIP="192.168.1.179"        # a FREE address on the same subnet
SSH_USER="vagrant"
SSH_KEY="$HOME/.ssh/id_rsa"
```

The label decides everything: `master-*` → control plane, `worker-*` → worker, and it
becomes both the VM hostname and the Kubernetes node name. A trailing third field is
applied verbatim as `kubectl label` key/values.

Single-node-control-plane lab? Leave `VIP=""` and list one master.

## 3. Build

```bash
./deploy.sh preflight     # reachability, sudo, OS, CPU/RAM, IP sanity, VIP reachable
./deploy.sh deploy        # the whole thing, ~8-15 min
```

What `deploy` does, in order:

1. **preflight** — refuses to touch anything if a VM is misconfigured.
2. **prep (all nodes, in parallel)** — hostname + `/etc/hosts`, swap off, `br_netfilter`
   / `ip_forward`, ufw off, containerd with `SystemdCgroup=true`, kubeadm/kubelet/kubectl
   pinned via `apt-mark hold`, `kubelet --node-ip=<your IP>` (essential on multi-NIC
   VirtualBox VMs), image pre-pull.
3. **VIP** — HAProxy on every master load-balances `VIP:8443 → each master:6443`;
   Keepalived floats the VIP with a health check, priorities 200/190/180, `nopreempt`.
4. **init** — `kubeadm init --upload-certs` on `master-1` with `controlPlaneEndpoint`
   set to the VIP and all master IPs/names in the apiserver cert SANs.
5. **CNI** — Calico with `IP_AUTODETECTION_METHOD=can-reach=<master-1>` so it binds the
   bridged NIC instead of the duplicated NAT address.
6. **join** — remaining masters one at a time (etcd quorum), workers in parallel.
7. **label**, fetch `./kubeconfig`, print status.

Per-node logs land in `logs/`. Every step is idempotent — re-run `deploy` after fixing
a problem and it skips what is already done.

## 4. Use it

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           AGE   VERSION   INTERNAL-IP
master-1   Ready    control-plane   9m    v1.33.x   192.168.1.180
master-2   Ready    control-plane   6m    v1.33.x   192.168.1.181
master-3   Ready    control-plane   5m    v1.33.x   192.168.1.182
worker-1   Ready    worker          3m    v1.33.x   192.168.1.183
...
```

## Day-2 commands

| Command | Effect |
|---|---|
| `./deploy.sh status` | nodes, unhealthy pods, etcd members, which master holds the VIP |
| `./deploy.sh add worker-4 192.168.1.186 zone=b` | prep + join a brand-new node (then add it to `cluster.conf`) |
| `./deploy.sh add worker-2` | re-add a node that is already in `cluster.conf` |
| `./deploy.sh add master-4 192.168.1.187` | joins a control-plane node and re-renders HAProxy |
| `./deploy.sh kubeconfig` | re-fetch the admin kubeconfig |
| `./deploy.sh reset worker-2` | drain, delete, and `kubeadm reset` one node |
| `FORCE=yes ./deploy.sh reset` | wipe Kubernetes from every VM (the VMs survive) |

### Removing and re-adding a node

```bash
./deploy.sh reset worker-2      # drain -> delete from the cluster -> kubeadm reset the VM
./deploy.sh add   worker-2      # prep -> join -> re-label
```

No IP needed on the way back: `worker-2` is still listed in `cluster.conf`, so `add`
reuses that entry's IP and extra labels instead of creating a second one. Passing an IP
that contradicts the config is refused — edit `cluster.conf` if the address really changed.

What each half does:

* **`reset worker-2`** — `kubectl drain` (evicting pods, ignoring daemonsets), `kubectl
  delete node`, then `kubeadm reset -f` on the VM plus CNI interfaces, iptables rules and
  `/etc/kubernetes`. The VM itself, containerd, and the kubeadm packages all survive.
* **`add worker-2`** — re-runs `node-prep.sh` (fast the second time; packages are already
  installed), mints a fresh join token, joins, re-applies `node-role.kubernetes.io/worker`
  and any extra labels, then prints cluster status.

`./deploy.sh deploy` does the same thing for *every* missing node, so it is the shortcut
when you have reset several at once — already-joined nodes are skipped.

Re-adding a **master** works the same way (`./deploy.sh add master-2`) and additionally
re-renders HAProxy on all masters. Make sure the etcd member is really gone first —
`reset master-2` removes it, but if you powered the VM off instead, remove the stale
member before re-joining or etcd will reject it:

```bash
kubectl -n kube-system exec -it etcd-master-1 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key member list      # find the id
# then: ... member remove <id>
```

**HA test:** `vagrant halt master-1` (or power it off in the VirtualBox GUI), wait ~5 s,
then `kubectl get nodes` again. Keepalived moves the VIP to `master-2` and the API keeps
answering; etcd holds quorum with 2 of 3 members.

## Options in `cluster.conf`

| Variable | Default | Notes |
|---|---|---|
| `K8S_VERSION` | `1.33` | apt repo minor version (`pkgs.k8s.io/core:/stable:/v1.33`) |
| `CNI` | `calico` | or `flannel` |
| `POD_CIDR` / `SERVICE_CIDR` | `10.244.0.0/16` / `10.96.0.0/12` | must not overlap your LAN |
| `VIP_PORT` | `8443` | HAProxy front end; the apiservers stay on 6443 |
| `VRRP_ROUTER_ID` | `51` | change if another Keepalived runs on the same L2 |
| `CNI_IFACE_DETECT` | `auto` | `can-reach=<master-1>`; or e.g. `interface=enp0s8` |
| `SSH_PASSWORD` | empty | password auth instead of keys — needs `sshpass` |
| `SUDO_PASSWORD` | empty | set when sudo is not NOPASSWD |

## Troubleshooting

**`kubeadm init` times out at "waiting for the kubelet to boot up"** — almost always swap
or the cgroup driver. `systemctl status kubelet`, `journalctl -xeu kubelet`. Prep sets
both, so this usually means containerd was already configured differently: delete
`/etc/containerd/config.toml`, re-run `./deploy.sh prep`.

**Nodes Ready but pods can't reach each other** — the CNI picked the NAT interface. Check
`kubectl -n kube-system get ds calico-node -o yaml | grep -A2 AUTODETECTION` and set
`CNI_IFACE_DETECT="interface=enp0s8"` to the real host-only device name.

**VIP never comes up** — `systemctl status keepalived` on the masters; the host-only
adapter needs promiscuous mode "Allow All", and `VRRP_ROUTER_ID` must be unique on the L2
segment.

**Node joins with the wrong IP** — `/etc/default/kubelet` should contain
`--node-ip=<host-only IP>`; re-run `./deploy.sh prep` and `systemctl restart kubelet`.

**Running the scripts from Windows** — use Git Bash or WSL, and make sure the files keep
LF endings (`git config core.autocrlf input`, or `dos2unix deploy.sh lib/*.sh`).
