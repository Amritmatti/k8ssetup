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

## 1. Prepare the VMs

Six VMs (3 masters, 3 workers) of Ubuntu 22.04/24.04 or Debian 12, each with:

* **2 vCPU / 2 GB RAM minimum** for masters (kubeadm refuses less than 2 CPUs)
* **Two network adapters**: NAT (internet) + **Host-only or Bridged** (cluster traffic).
  The host-only address is what goes into `cluster.conf` — never `10.0.2.15`, which
  every NAT adapter shares.
* An SSH user with **passwordless sudo** (Vagrant's `vagrant` user already has it),
  and your public key in `~/.ssh/authorized_keys`.
* **Promiscuous mode = Allow All** on the host-only adapter of the masters, so the
  Keepalived VIP can float between them.

No VMs yet? `vagrant up` with the bundled `Vagrantfile` builds all six.

## 2. Describe the cluster

```bash
NODES=(
  "master-1  192.168.56.11"
  "master-2  192.168.56.12"
  "master-3  192.168.56.13"
  "worker-1  192.168.56.21"
  "worker-2  192.168.56.22"
  "worker-3  192.168.56.23   disk=ssd,zone=lab"   # optional extra labels
)
VIP="192.168.56.10"        # a FREE address on the same subnet
SSH_USER="vagrant"
SSH_KEY="$HOME/.ssh/id_rsa"
```

The label decides everything: `master-*` → control plane, `worker-*` → worker, and it
becomes both the VM hostname and the Kubernetes node name. A trailing third field is
applied verbatim as `kubectl label` key/values.

Single-node-control-plane lab? Leave `VIP=""` and list one master.

## 3. Build

```bash
./deploy.sh preflight     # reachability, sudo, OS, CPU/RAM, IP sanity, VIP free
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
   host-only NIC instead of the duplicated NAT address.
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
master-1   Ready    control-plane   9m    v1.33.x   192.168.56.11
master-2   Ready    control-plane   6m    v1.33.x   192.168.56.12
master-3   Ready    control-plane   5m    v1.33.x   192.168.56.13
worker-1   Ready    worker          3m    v1.33.x   192.168.56.21
...
```

## Day-2 commands

| Command | Effect |
|---|---|
| `./deploy.sh status` | nodes, unhealthy pods, etcd members, which master holds the VIP |
| `./deploy.sh add worker-4 192.168.56.24 zone=b` | prep + join one new node (then add it to `cluster.conf`) |
| `./deploy.sh add master-4 192.168.56.14` | joins a control-plane node and re-renders HAProxy |
| `./deploy.sh kubeconfig` | re-fetch the admin kubeconfig |
| `./deploy.sh reset worker-2` | drain, delete, and `kubeadm reset` one node |
| `FORCE=yes ./deploy.sh reset` | wipe Kubernetes from every VM (the VMs survive) |

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
