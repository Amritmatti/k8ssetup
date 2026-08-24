<#
.SYNOPSIS
    Clone a powered-off base VM into a set of Kubernetes nodes.

.DESCRIPTION
    Clones a powered-off base VM N times, gives each clone a bridged NIC,
    boots it, then logs in over SSH at the base IP and rewrites the node's
    hostname and static IP address. Clones are left RUNNING.

    Creates (defaults):
      k8s-master-1  192.168.1.180
      k8s-master-2  192.168.1.181
      k8s-master-3  192.168.1.182
      k8s-worker-1  192.168.1.183
      k8s-worker-2  192.168.1.184
      k8s-worker-3  192.168.1.185

    Masters and workers draw from SEPARATE reserved address blocks, so
    -Masters 1 -Workers 1 gives master-1 .180 and worker-1 .183 -- a worker
    never inherits an address reserved for a master it did not create.

    Clones are processed strictly one at a time: every clone boots holding
    the same base IP, so the previous one must be moved to its final address
    before the next may start.

.EXAMPLE
    .\vms.ps1
    Three masters and three workers, the full default layout.

.EXAMPLE
    .\vms.ps1 -Masters 1 -Workers 1
    master-1 (.180) and worker-1 (.183). Remember VIP="" in cluster.conf for
    a single-master cluster.

.EXAMPLE
    .\vms.ps1 -Masters 3 -Workers 2 -BaseVM ubuntu-2404-base -BaseIp 192.168.1.190 -WhatIf
    Show the plan without touching VirtualBox.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]    $Masters   = 3,
    [int]    $Workers   = 3,

    # Powered-off template VM, already running SSH with your key installed.
    [string] $BaseVM    = 'k8s-base',
    # Address the base image comes up on (DHCP reservation or its own static).
    [string] $BaseIp    = '192.168.1.190',

    # Reserved blocks. Each role indexes its OWN list -- this is the whole
    # point: worker numbering must not depend on how many masters were made.
    [string[]] $MasterIps = @('192.168.1.180', '192.168.1.181', '192.168.1.182'),
    [string[]] $WorkerIps = @('192.168.1.183', '192.168.1.184', '192.168.1.185'),

    [string] $Prefix    = 'k8s-',
    [string] $Gateway   = '192.168.1.1',
    [int]    $PrefixLen = 24,
    [string[]] $Dns     = @('192.168.1.1', '1.1.1.1'),

    [string] $Bridge    = '',          # host NIC to bridge onto; auto-detected if empty
    [int]    $Cpus      = 2,
    [int]    $MemoryMB  = 2560,

    [string] $SshUser   = 'ubuntu',
    [string] $SshKey    = '',          # e.g. $HOME\.ssh\id_rsa ; empty = default/agent
    [switch] $Linked,                  # linked clone (fast, small) instead of full
    [switch] $Force,                   # skip the confirmation prompt
    [switch] $SkipUpgrade              # do not apt update/upgrade the clones
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ---
function Write-Step { param([string]$Msg) Write-Host "`n--- $Msg " -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  ok   $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "  ==>  $Msg" -ForegroundColor Gray }
function Write-Warn { param([string]$Msg) Write-Host "  warn $Msg" -ForegroundColor Yellow }

function Get-VBoxManage {
    $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw "VBoxManage.exe not found. Add VirtualBox to PATH or install it."
}

function Invoke-VBox {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $out = & $script:VBM @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage $($Args -join ' ') failed:`n$($out -join "`n")"
    }
    return $out
}

function Test-VMExists {
    param([string]$Name)
    $list = & $script:VBM list vms
    return ($list -match ('"' + [regex]::Escape($Name) + '"')) -ne $null -and
           ($list | Where-Object { $_ -match ('^"' + [regex]::Escape($Name) + '"') }).Count -gt 0
}

function Get-VMState {
    param([string]$Name)
    $info = & $script:VBM showvminfo $Name --machinereadable 2>$null
    $line = $info | Where-Object { $_ -like 'VMState=*' } | Select-Object -First 1
    if ($line) { return $line.Split('=')[1].Trim('"') }
    return 'unknown'
}

function Test-Ping {
    param([string]$Ip)
    return (Test-Connection -ComputerName $Ip -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

function Get-SshArgs {
    $a = @('-o', 'StrictHostKeyChecking=no',
           '-o', 'UserKnownHostsFile=/dev/null',
           '-o', 'LogLevel=ERROR',
           '-o', 'ConnectTimeout=10')
    if ($SshKey) { $a += @('-i', $SshKey) }
    return $a
}

function Invoke-Ssh {
    param([string]$Ip, [string]$Command, [switch]$IgnoreExit)
    $sshArgs = (Get-SshArgs) + @("$SshUser@$Ip", $Command)
    $out = & ssh @sshArgs 2>&1
    if (-not $IgnoreExit -and $LASTEXITCODE -ne 0) {
        throw "ssh $SshUser@$Ip failed:`n$($out -join "`n")"
    }
    return $out
}

# Invoke-Ssh collects the output and hands it back, which is right for a
# command that answers in a line or two. A full apt upgrade runs for minutes
# and says a great deal on the way; held back to the end it is both a wall of
# text and, while it is running, indistinguishable from a hang.
function Invoke-SshLive {
    param([string]$Ip, [string]$Command, [switch]$IgnoreExit)
    $sshArgs = (Get-SshArgs) + @("$SshUser@$Ip", $Command)
    & ssh @sshArgs 2>&1 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    if (-not $IgnoreExit -and $LASTEXITCODE -ne 0) {
        throw "ssh $SshUser@$Ip failed (exit $LASTEXITCODE)"
    }
}

function Wait-Ssh {
    param([string]$Ip, [int]$TimeoutSec = 300, [string]$What = 'SSH')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $sshArgs = (Get-SshArgs) + @('-o', 'BatchMode=yes', "$SshUser@$Ip", 'echo ready')
        $out = & ssh @sshArgs 2>&1
        if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'ready') { return $true }
        Start-Sleep -Seconds 5
    }
    throw "timed out after ${TimeoutSec}s waiting for $What on $Ip"
}

# --------------------------------------------------------------- planning ---
$script:VBM = Get-VBoxManage
$script:NeedReboot = @()

if ($Masters -lt 0 -or $Workers -lt 0) { throw "-Masters and -Workers cannot be negative" }
if (($Masters + $Workers) -eq 0)       { throw "nothing to do: both -Masters and -Workers are 0" }
if ($Masters -gt $MasterIps.Count) {
    throw "-Masters $Masters but only $($MasterIps.Count) master IP(s) reserved. Extend -MasterIps."
}
if ($Workers -gt $WorkerIps.Count) {
    throw "-Workers $Workers but only $($WorkerIps.Count) worker IP(s) reserved. Extend -WorkerIps."
}

# Build the node list. Each role is indexed from ITS OWN array, so the worker
# addresses never shift with the master count. @() keeps a single element an
# array -- a bare PowerShell slice of one item is a scalar and breaks .Count.
$nodes = @()
for ($i = 0; $i -lt $Masters; $i++) {
    $nodes += [pscustomobject]@{
        Name  = "$Prefix`master-$($i + 1)"
        Node  = "master-$($i + 1)"
        Ip    = @($MasterIps)[$i]
        Role  = 'master'
    }
}
for ($i = 0; $i -lt $Workers; $i++) {
    $nodes += [pscustomobject]@{
        Name  = "$Prefix`worker-$($i + 1)"
        Node  = "worker-$($i + 1)"
        Ip    = @($WorkerIps)[$i]
        Role  = 'worker'
    }
}

# Nothing may share an address, including the base image.
$dupes = $nodes | Group-Object Ip | Where-Object { $_.Count -gt 1 }
if ($dupes) { throw "duplicate IP(s) in the plan: $(($dupes | ForEach-Object { $_.Name }) -join ', ')" }
if ($nodes.Ip -contains $BaseIp) {
    throw "-BaseIp $BaseIp collides with a node address; the base image needs its own"
}

Write-Step "plan"
$nodes | Format-Table Name, Node, Role, Ip -AutoSize | Out-String | Write-Host
Write-Info "base VM     : $BaseVM (at $BaseIp, user $SshUser)"
Write-Info "clone type  : $(if ($Linked) { 'linked' } else { 'full' })"
Write-Info "per clone   : $Cpus vCPU, $MemoryMB MB, bridged NIC, promiscuous allow-all"

# ----------------------------------------------------------- sanity checks ---
Write-Step "checks"
if (-not (Test-VMExists $BaseVM)) { throw "base VM '$BaseVM' does not exist in VirtualBox" }
$baseState = Get-VMState $BaseVM
if ($baseState -ne 'poweroff' -and $baseState -ne 'saved') {
    throw "base VM '$BaseVM' is '$baseState' -- power it off before cloning"
}
Write-Ok "base VM '$BaseVM' is $baseState"

foreach ($n in $nodes) {
    if (Test-VMExists $n.Name) { throw "VM '$($n.Name)' already exists -- delete it or pick another -Prefix" }
}
Write-Ok "no name collisions in VirtualBox"

foreach ($n in $nodes) {
    if (Test-Ping $n.Ip) { throw "$($n.Ip) already answers ping -- it is in use (DHCP lease or an old VM)" }
}
Write-Ok "every target address is free"

if (-not $Bridge) {
    $bridged = & $script:VBM list bridgedifs
    $Bridge = ($bridged | Where-Object { $_ -like 'Name:*' } | Select-Object -First 1) -replace '^Name:\s*', ''
    if (-not $Bridge) { throw "no bridged interface found; pass -Bridge '<host NIC name>'" }
    Write-Warn "auto-selected bridge NIC: $Bridge (override with -Bridge)"
} else {
    Write-Ok "bridge NIC: $Bridge"
}

if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host "  Create $($nodes.Count) VM(s)? Type 'yes' to continue"
    if ($answer -ne 'yes') { Write-Host "  aborted"; return }
}

# ------------------------------------------------------------------- work ---
# One clone at a time: each boots holding $BaseIp, so the previous clone must
# have moved to its final address before the next one starts.
foreach ($n in $nodes) {
    Write-Step "$($n.Name) -> $($n.Ip)"

    if (-not $PSCmdlet.ShouldProcess($n.Name, "clone from $BaseVM and set IP $($n.Ip)")) { continue }

    if (Test-Ping $BaseIp) {
        throw "$BaseIp is still in use -- the previous clone did not move off the base address"
    }

    $cloneArgs = @('clonevm', $BaseVM, '--name', $n.Name, '--register')
    if ($Linked) { $cloneArgs += @('--options', 'link', '--snapshot', 'base') }
    else         { $cloneArgs += @('--mode', 'machine') }
    Write-Info "cloning"
    Invoke-VBox @cloneArgs | Out-Null

    Write-Info "configuring hardware"
    Invoke-VBox modifyvm $n.Name --cpus $Cpus --memory $MemoryMB | Out-Null
    Invoke-VBox modifyvm $n.Name --nic1 bridged --bridgeadapter1 $Bridge `
                --nicpromisc1 allow-all --macaddress1 auto | Out-Null
    Invoke-VBox modifyvm $n.Name --groups '/k8s-lab' | Out-Null

    Write-Info "booting (headless)"
    Invoke-VBox startvm $n.Name --type headless | Out-Null

    Write-Info "waiting for SSH on the base address $BaseIp"
    Wait-Ssh -Ip $BaseIp -TimeoutSec 300 -What "$($n.Name) at the base address" | Out-Null

    # Hostname + a netplan file for the final address. cloud-init's network
    # config is disabled first, or it rewrites netplan on the next boot and
    # the node silently returns to the base address.
    $remote = @"
set -e
sudo hostnamectl set-hostname '$($n.Node)'
sudo sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo '127.0.1.1 $($n.Node)' | sudo tee -a /etc/hosts >/dev/null
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
IFACE=`$(ip -o -4 route show default | awk '{print `$5}' | head -1)
sudo rm -f /etc/netplan/*.yaml
sudo tee /etc/netplan/99-k8s.yaml >/dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    `$IFACE:
      dhcp4: no
      addresses: [$($n.Ip)/$PrefixLen]
      routes:
        - to: default
          via: $Gateway
      nameservers:
        addresses: [$($Dns -join ', ')]
EOF
sudo chmod 600 /etc/netplan/99-k8s.yaml
sudo netplan generate
# Apply detached: this SSH session dies the moment the address changes.
sudo sh -c 'nohup netplan apply >/dev/null 2>&1 &'
"@
    Write-Info "setting hostname '$($n.Node)' and address $($n.Ip)"
    Invoke-Ssh -Ip $BaseIp -Command $remote -IgnoreExit | Out-Null

    Write-Info "waiting for $($n.Node) on its new address"
    Wait-Ssh -Ip $n.Ip -TimeoutSec 240 -What "$($n.Node) on its new address" | Out-Null

    $hn = (Invoke-Ssh -Ip $n.Ip -Command 'hostname' | Select-Object -First 1).ToString().Trim()
    if ($hn -ne $n.Node) { Write-Warn "hostname reads '$hn', expected '$($n.Node)'" }
    Write-Ok "$($n.Name) is up as $hn on $($n.Ip)"

    if (-not $SkipUpgrade) {
        # apt-get rather than apt: apt prints "does not have a stable CLI
        # interface. Use with caution in scripts" precisely because it does not.
        #
        # Held packages are answered from the package's own config, not from a
        # prompt nobody is there to answer -- confdef/confold keep whatever the
        # image already has wherever a maintainer script would otherwise stop
        # and ask, which on an unattended clone is the difference between a
        # finished upgrade and one waiting forever on a dialog.
        $upgrade = @"
set -e
export DEBIAN_FRONTEND=noninteractive
# A just-booted Ubuntu is usually still running unattended-upgrades, and it
# holds the dpkg lock while it does. Wait it out rather than failing on it.
for i in `$(seq 1 90); do
  sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  [ `$i -eq 1 ] && echo 'waiting for the dpkg lock (unattended-upgrades is running)'
  sleep 5
done
APT_OPTS='-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
sudo apt-get update
sudo apt-get `$APT_OPTS upgrade
sudo apt-get `$APT_OPTS full-upgrade
if [ -f /var/run/reboot-required ]; then echo 'REBOOT-REQUIRED'; fi
"@
        Write-Info "apt update / upgrade / full-upgrade (this takes a few minutes)"
        Invoke-SshLive -Ip $n.Ip -Command $upgrade

        # A kernel or libc upgrade wants a reboot. Saying so beats leaving the
        # node running the packages it booted with and the ones it now has.
        $rebootNeeded = Invoke-Ssh -Ip $n.Ip -IgnoreExit `
            -Command 'test -f /var/run/reboot-required && echo YES || echo NO'
        if (($rebootNeeded -join '') -match 'YES') {
            Write-Warn "$($n.Node) wants a reboot to finish the upgrade (kernel or libc)"
            $script:NeedReboot += $n.Node
        }
        Write-Ok "$($n.Node) is up to date"
    }
}

# ----------------------------------------------------------------- output ---
if ($WhatIfPreference) { return }

Write-Step "done"
if ($script:NeedReboot.Count -gt 0) {
    Write-Warn ("these nodes want a reboot before deploy.sh: " + ($script:NeedReboot -join ', '))
    Write-Host "  VBoxManage controlvm <vm> acpipowerbutton, then start it again -- or"
    Write-Host "  ssh $SshUser@<ip> 'sudo reboot' and wait for it to come back.`n"
}
Write-Host "  Paste this into k8s-cluster/cluster.conf:`n"
Write-Host "NODES=("
foreach ($n in $nodes) { Write-Host ("  `"{0,-9} {1}`"" -f $n.Node, $n.Ip) }
Write-Host ")"
if ($Masters -lt 2) {
    Write-Host 'VIP=""    # single master: no HA endpoint, deploy.sh skips HAProxy/Keepalived'
} else {
    Write-Host 'VIP="192.168.1.179"    # must be free and on the same subnet'
}
Write-Host "`n  Then:  cd k8s-cluster && ./deploy.sh preflight && ./deploy.sh deploy"
