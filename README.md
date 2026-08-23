# OCI: VCN + public subnet + NSG + Ubuntu 24.04 VM

Terraform for Oracle Cloud Infrastructure that builds a publicly reachable VM.

| OCI term | Common name |
|---|---|
| VCN | VPC |
| Network Security Group (NSG) | Security group |
| Security list | Subnet-level ACL |

## What gets created

- **VCN** `10.0.0.0/16`
- **Internet gateway** + public route table (`0.0.0.0/0` → IGW)
- **Public subnet** `10.0.1.0/24`, public IPs allowed
- **Security list** — egress only; all ingress filtering is in the NSG
- **NSG** attached to the VM's VNIC:
  - TCP **80** from `0.0.0.0/0`
  - TCP **443** from `0.0.0.0/0`
  - TCP **22** from `var.ssh_allowed_cidr` only
  - ICMP 3/4 (path-MTU discovery)
  - all egress
- **VM** — Canonical Ubuntu 24.04, 4 OCPU / 24 GB, 50 GB boot volume, public IP,
  cloud-init that opens 80/443 in the host firewall and installs nginx

Note on the two layers: OCI *unions* security-list and NSG rules, so a restrictive
security list cannot override an NSG. Ingress is therefore left empty on the
security list and the NSG is the single source of truth.

## Always Free

This config defaults to exactly Oracle's perpetual free allocation, and refuses
to apply if you drift outside it. Only the Ampere A1 shape is free — Intel
(`VM.Standard3.Flex`) and AMD (`VM.Standard.E5.Flex`) are billed hourly at this
size, and setting either requires `enforce_always_free_limits = false`.

| Resource | Always Free allocation |
|---|---|
| Ampere A1 (`VM.Standard.A1.Flex`) | **4 OCPU + 24 GB RAM total**, one VM or split across up to 4 |
| AMD micro (`VM.Standard.E2.1.Micro`) | 2 instances, 1/8 OCPU + 1 GB each |
| Block storage | 200 GB total across all boot + block volumes |
| Outbound transfer | 10 TB / month |

Three conditions must hold for the VM to be free, and each is enforced by a
`precondition` on the instance:

1. **Shape is `VM.Standard.A1.Flex`.** An E5.Flex at 4 OCPU / 24 GB is billed.
2. **4 OCPU / 24 GB or less.** The pool is tenancy-wide — if you already run
   other A1 instances, this one must fit in what is left, which Terraform
   cannot see. That one is on you.
3. **Region is the tenancy home region.** Always Free capacity exists nowhere
   else. Terraform resolves the home region from the tenancy and compares.

The `always_free` and `cost_summary` outputs report which side of the line the
current settings land on, whether or not enforcement is switched on.

## Prerequisites

1. Terraform >= 1.5
2. An OCI API signing key (see below).
3. An SSH keypair for the `ubuntu` user (`ssh-keygen -t ed25519`).

### Getting `fingerprint`, `user_ocid` and `private_key_path`

The fingerprint is an MD5 hash of the **public** half of an API signing key, and
it only exists once that key is registered against your OCI user. It is not
something you invent or look up before uploading a key.

**Easiest path — let the console generate the key:**

1. Sign in to the OCI Console.
2. Top-right profile icon -> **My profile**.
3. Left sidebar, under Resources -> **API keys** -> **Add API key**.
4. Choose **Generate API key pair**, click **Download private key**, and save it
   as e.g. `C:/Users/<you>/.oci/oci_api_key.pem` — that path is `private_key_path`.
5. Click **Add**. The console then shows a **Configuration file preview**
   containing every value you need:

   ```
   [DEFAULT]
   user=ocid1.user.oc1..xxxx          <- user_ocid
   fingerprint=aa:bb:cc:dd:...:99     <- fingerprint
   tenancy=ocid1.tenancy.oc1..xxxx    <- tenancy_ocid
   region=eu-frankfurt-1              <- region
   ```

   Copy those into `terraform.tfvars`. If you navigate away, the fingerprint
   stays listed in the API keys table on that same page.

**If you generated the key yourself**, upload the public half via the same
**Add API key** -> *Paste a public key* flow. You can also compute the
fingerprint locally from the private key:

```bash
openssl rsa -pubout -outform DER -in oci_api_key.pem | openssl md5 -c
```

**If you have the OCI CLI**, `oci setup config` does the whole dance and writes
`~/.oci/config` with all four values in it.

Use forward slashes in `private_key_path` on Windows, and lock the file down
(`icacls`) — the provider warns about world-readable keys.

### Getting `compartment_ocid`

A compartment is the logical folder resources live in. **It is optional here** —
leave it unset and everything is built in the tenancy's *root* compartment, whose
OCID is simply the tenancy OCID. A fresh free-tier tenancy has nothing else, so
this is the normal case.

To use a real compartment instead:

1. Console -> hamburger menu -> **Identity & Security** -> **Compartments**
2. Click the compartment (or **Create Compartment** first)
3. **Copy** next to the OCID field -> paste into `compartment_ocid`

Or with the CLI: `oci iam compartment list --all --compartment-id-in-subtree true`

Note that a compartment OCID starts `ocid1.compartment.oc1..` while the root one
starts `ocid1.tenancy.oc1..` — both are valid values for this variable.


## Usage

```powershell
cd D:\Oracle
copy terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — especially ssh_allowed_cidr and ssh_public_key

terraform init
terraform plan
terraform apply
```

Then:

```powershell
terraform output public_ip
curl http://<public_ip>          # nginx welcome page
ssh ubuntu@<public_ip>           # only from ssh_allowed_cidr
```

Tear down with `terraform destroy`.

## Files

| File | Purpose |
|---|---|
| `providers.tf` | Terraform + OCI provider config |
| `variables.tf` | All inputs |
| `network.tf` | VCN, IGW, route table, subnet, security list, NSG rules |
| `compute.tf` | AD + image lookup, VM instance |
| `cloud-init.yaml.tftpl` | Host firewall rules + nginx |
| `outputs.tf` | IPs, OCIDs, ready-made SSH command |

## Gotchas

- `ssh_allowed_cidr` is validated and **rejects `0.0.0.0/0`** — that is the point
  of this config. Use your own IP as a `/32`.
- Ampere A1 capacity is frequently exhausted, precisely because it is free; an
  `Out of host capacity` error on apply means retry later. Switching region is
  not an option if you want it free — see Always Free above.
- The OCI Ubuntu image ships an iptables ruleset that only permits SSH. cloud-init
  opens 80/443 there; without that step the NSG rules alone would not be enough.
- Boot volume minimum is 50 GB; the free allowance is 200 GB total across all
  boot and block volumes in the tenancy.
