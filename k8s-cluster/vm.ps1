# ============================================================
# VirtualBox VM Manager
#
# Commands:
#
#   .\vm.ps1 start vm1 vm2 vm3
#   .\vm.ps1 stop vm1 vm2 vm3
#   .\vm.ps1 force-stop vm1 vm2
#   .\vm.ps1 restart vm1 vm2
#   .\vm.ps1 status vm1 vm2
#   .\vm.ps1 list
#
#   .\vm.ps1 start-all
#   .\vm.ps1 stop-all
#   .\vm.ps1 status-all
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"


# ------------------------------------------------------------
# Define your OpenShift / Lab VMs here
#
# START ORDER:
#   Bootstrap
#   Masters
#   Workers
#
# STOP ORDER:
#   Workers
#   Masters
#   Bootstrap
# ------------------------------------------------------------

$BootstrapVMs = @(
    "kotak",
	"Ubuntu-1"
)

$MasterVMs = @(
    "k8s-master-1",
    "k8s-master-2",
    "k8s-master-3"
)

$WorkerVMs = @(
    "k8s-worker-1",
    "k8s-worker-2",
    "k8s-worker-3"
)


# ============================================================
# CHECK VBoxManage
# ============================================================

if (-not (Test-Path $VBoxManage)) {

    Write-Host ""
    Write-Host "ERROR: VBoxManage.exe not found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected location:" -ForegroundColor Yellow
    Write-Host $VBoxManage
    Write-Host ""

    exit 1
}


# ============================================================
# FUNCTION: Get VM State
# ============================================================

function Get-VMState {

    param (
        [string]$VM
    )

    $Info = & $VBoxManage showvminfo "$VM" --machinereadable 2>$null

    if ($LASTEXITCODE -ne 0) {
        return "NOTFOUND"
    }

    $StateLine = $Info |
        Select-String '^VMState=' |
        Select-Object -First 1

    if ($null -eq $StateLine) {
        return "UNKNOWN"
    }

    return ($StateLine.ToString() -split '=')[1].Trim('"')
}


# ============================================================
# FUNCTION: Start VM
# ============================================================

function Start-VM {

    param (
        [string]$VM
    )

    Write-Host ""
    Write-Host "Starting: $VM" -ForegroundColor Cyan

    $State = Get-VMState $VM

    if ($State -eq "NOTFOUND") {

        Write-Host "  VM not found!" -ForegroundColor Red
        return
    }

    if ($State -eq "running") {

        Write-Host "  Already running." -ForegroundColor Green
        return
    }

    & $VBoxManage startvm "$VM" --type gui

    if ($LASTEXITCODE -eq 0) {

        Write-Host "  Started successfully." -ForegroundColor Green

    }
    else {

        Write-Host "  Failed to start." -ForegroundColor Red
    }
}


# ============================================================
# FUNCTION: Stop VM - Graceful
# ============================================================

function Stop-VM {

    param (
        [string]$VM
    )

    Write-Host ""
    Write-Host "Stopping: $VM" -ForegroundColor Cyan

    $State = Get-VMState $VM

    if ($State -eq "NOTFOUND") {

        Write-Host "  VM not found!" -ForegroundColor Red
        return
    }

    if ($State -eq "poweroff") {

        Write-Host "  Already powered off." -ForegroundColor Green
        return
    }

    if ($State -ne "running") {

        Write-Host "  Current state: $State" -ForegroundColor Yellow
        return
    }

    # Graceful ACPI shutdown

    & $VBoxManage controlvm "$VM" acpipowerbutton

    if ($LASTEXITCODE -eq 0) {

        Write-Host "  Shutdown signal sent." -ForegroundColor Green

    }
    else {

        Write-Host "  Failed to send shutdown signal." -ForegroundColor Red
    }
}


# ============================================================
# FUNCTION: Force Stop
# ============================================================

function Force-Stop-VM {

    param (
        [string]$VM
    )

    Write-Host ""
    Write-Host "FORCE POWER OFF: $VM" -ForegroundColor Red

    $State = Get-VMState $VM

    if ($State -eq "NOTFOUND") {

        Write-Host "  VM not found!" -ForegroundColor Red
        return
    }

    if ($State -eq "poweroff") {

        Write-Host "  Already powered off." -ForegroundColor Green
        return
    }

    & $VBoxManage controlvm "$VM" poweroff

    if ($LASTEXITCODE -eq 0) {

        Write-Host "  VM powered off." -ForegroundColor Green

    }
    else {

        Write-Host "  Failed." -ForegroundColor Red
    }
}


# ============================================================
# FUNCTION: Restart VM
# ============================================================

function Restart-VM {

    param (
        [string]$VM
    )

    Write-Host ""
    Write-Host "Restarting: $VM" -ForegroundColor Cyan

    $State = Get-VMState $VM

    if ($State -eq "NOTFOUND") {

        Write-Host "  VM not found!" -ForegroundColor Red
        return
    }

    if ($State -eq "running") {

        Write-Host "  Sending graceful shutdown..." -ForegroundColor Yellow

        & $VBoxManage controlvm "$VM" acpipowerbutton

        if ($LASTEXITCODE -ne 0) {

            Write-Host "  Failed to send shutdown signal." -ForegroundColor Red
            return
        }

        Write-Host "  Waiting for shutdown..." -ForegroundColor Yellow

        $Timeout = 60
        $Elapsed = 0

        while ($Elapsed -lt $Timeout) {

            Start-Sleep -Seconds 2
            $Elapsed += 2

            $CurrentState = Get-VMState $VM

            if ($CurrentState -eq "poweroff") {
                break
            }

            Write-Host "  Still running... ($Elapsed sec)"
        }

        $CurrentState = Get-VMState $VM

        if ($CurrentState -ne "poweroff") {

            Write-Host ""
            Write-Host "  VM did not shut down within $Timeout seconds." -ForegroundColor Red
            Write-Host "  Restart cancelled." -ForegroundColor Red

            return
        }
    }

    Write-Host "  Starting VM..." -ForegroundColor Yellow

    & $VBoxManage startvm "$VM" --type gui

    if ($LASTEXITCODE -eq 0) {

        Write-Host "  Restarted successfully." -ForegroundColor Green

    }
    else {

        Write-Host "  Failed to restart." -ForegroundColor Red
    }
}


# ============================================================
# FUNCTION: Show VM Status
# ============================================================

function Show-VMStatus {

    param (
        [string]$VM
    )

    $State = Get-VMState $VM

    switch ($State) {

        "running" {

            Write-Host ("{0,-30} RUNNING" -f $VM) -ForegroundColor Green
        }

        "poweroff" {

            Write-Host ("{0,-30} POWER OFF" -f $VM) -ForegroundColor Gray
        }

        "NOTFOUND" {

            Write-Host ("{0,-30} NOT FOUND" -f $VM) -ForegroundColor Red
        }

        default {

            Write-Host ("{0,-30} {1}" -f $VM, $State) -ForegroundColor Yellow
        }
    }
}


# ============================================================
# FUNCTION: STATUS ALL
# ============================================================

function Show-Status-All {

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "             OPENSHIFT LAB STATUS" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "[ BOOTSTRAP ]" -ForegroundColor Yellow

    foreach ($VM in $BootstrapVMs) {
        Show-VMStatus $VM
    }

    Write-Host ""
    Write-Host "[ CONTROL PLANE / MASTERS ]" -ForegroundColor Yellow

    foreach ($VM in $MasterVMs) {
        Show-VMStatus $VM
    }

    Write-Host ""
    Write-Host "[ WORKERS ]" -ForegroundColor Yellow

    foreach ($VM in $WorkerVMs) {
        Show-VMStatus $VM
    }

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
}


# ============================================================
# FUNCTION: START ALL
# ============================================================

function Start-All {

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "          STARTING OPENSHIFT LAB"
    Write-Host "==================================================" -ForegroundColor Cyan

    # --------------------------------------------------------
    # Bootstrap
    # --------------------------------------------------------

    if ($BootstrapVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[1/3] Starting Bootstrap..." -ForegroundColor Yellow

        foreach ($VM in $BootstrapVMs) {

            Start-VM $VM
        }
    }


    # --------------------------------------------------------
    # Masters
    # --------------------------------------------------------

    if ($MasterVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[2/3] Starting Masters..." -ForegroundColor Yellow

        foreach ($VM in $MasterVMs) {

            Start-VM $VM
        }
    }


    # --------------------------------------------------------
    # Workers
    # --------------------------------------------------------

    if ($WorkerVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[3/3] Starting Workers..." -ForegroundColor Yellow

        foreach ($VM in $WorkerVMs) {

            Start-VM $VM
        }
    }

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "          OPENSHIFT LAB START COMPLETE"
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
}


# ============================================================
# FUNCTION: STOP ALL
# ============================================================

function Stop-All {

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "          STOPPING OPENSHIFT LAB"
    Write-Host "==================================================" -ForegroundColor Cyan

    # --------------------------------------------------------
    # Workers FIRST
    # --------------------------------------------------------

    if ($WorkerVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[1/3] Stopping Workers..." -ForegroundColor Yellow

        foreach ($VM in $WorkerVMs) {

            Stop-VM $VM
        }
    }


    # --------------------------------------------------------
    # Masters SECOND
    # --------------------------------------------------------

    if ($MasterVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[2/3] Stopping Masters..." -ForegroundColor Yellow

        foreach ($VM in $MasterVMs) {

            Stop-VM $VM
        }
    }


    # --------------------------------------------------------
    # Bootstrap LAST
    # --------------------------------------------------------

    if ($BootstrapVMs.Count -gt 0) {

        Write-Host ""
        Write-Host "[3/3] Stopping Bootstrap..." -ForegroundColor Yellow

        foreach ($VM in $BootstrapVMs) {

            Stop-VM $VM
        }
    }

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "          OPENSHIFT LAB STOP COMPLETE"
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
}


# ============================================================
# FUNCTION: LIST VMS
# ============================================================

function Show-AllVMs {

    Write-Host ""
    Write-Host "VirtualBox VMs" -ForegroundColor Cyan
    Write-Host "=================================================="

    & $VBoxManage list vms

    Write-Host ""
}


# ============================================================
# HELP
# ============================================================

function Show-Help {

    Write-Host ""
    Write-Host "VirtualBox OpenShift Lab Manager" -ForegroundColor Cyan
    Write-Host "=================================================="
    Write-Host ""
    Write-Host "Individual VM commands:"
    Write-Host ""
    Write-Host "  .\vm.ps1 start k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1"
    Write-Host "  .\vm.ps1 stop k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1"
    Write-Host "  .\vm.ps1 force-stop k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1"
    Write-Host "  .\vm.ps1 restart k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1"
    Write-Host "  .\vm.ps1 status k8s-master-1 k8s-master-2 k8s-master-3 k8s-worker-1 k8s-worker-2 k8s-worker-3 kotak Ubuntu-1"
    Write-Host ""
    Write-Host "OpenShift Lab commands:"
    Write-Host ""
    Write-Host "  .\vm.ps1 start-all"
    Write-Host "  .\vm.ps1 stop-all"
    Write-Host "  .\vm.ps1 status-all"
    Write-Host ""
    Write-Host "Other:"
    Write-Host ""
    Write-Host "  .\vm.ps1 list"
    Write-Host "  .\vm.ps1 help"
    Write-Host ""
}


# ============================================================
# COMMAND PROCESSING
# ============================================================

if ($args.Count -eq 0) {

    Show-Help
    exit 0
}


$Action = $args[0].ToLower()

$VMs = @()

if ($args.Count -gt 1) {

    $VMs = $args[1..($args.Count - 1)]
}


switch ($Action) {


    # --------------------------------------------------------
    # START
    # --------------------------------------------------------

    "start" {

        if ($VMs.Count -eq 0) {

            Write-Host "ERROR: Specify at least one VM." -ForegroundColor Red
            exit 1
        }

        foreach ($VM in $VMs) {

            Start-VM $VM
        }
    }


    # --------------------------------------------------------
    # STOP
    # --------------------------------------------------------

    "stop" {

        if ($VMs.Count -eq 0) {

            Write-Host "ERROR: Specify at least one VM." -ForegroundColor Red
            exit 1
        }

        foreach ($VM in $VMs) {

            Stop-VM $VM
        }
    }


    # --------------------------------------------------------
    # FORCE STOP
    # --------------------------------------------------------

    "force-stop" {

        if ($VMs.Count -eq 0) {

            Write-Host "ERROR: Specify at least one VM." -ForegroundColor Red
            exit 1
        }

        foreach ($VM in $VMs) {

            Force-Stop-VM $VM
        }
    }


    # --------------------------------------------------------
    # RESTART
    # --------------------------------------------------------

    "restart" {

        if ($VMs.Count -eq 0) {

            Write-Host "ERROR: Specify at least one VM." -ForegroundColor Red
            exit 1
        }

        foreach ($VM in $VMs) {

            Restart-VM $VM
        }
    }


    # --------------------------------------------------------
    # STATUS
    # --------------------------------------------------------

    "status" {

        if ($VMs.Count -eq 0) {

            Write-Host "ERROR: Specify at least one VM." -ForegroundColor Red
            exit 1
        }

        Write-Host ""
        Write-Host "VM STATUS" -ForegroundColor Cyan
        Write-Host "=================================================="

        foreach ($VM in $VMs) {

            Show-VMStatus $VM
        }

        Write-Host ""
    }


    # --------------------------------------------------------
    # START ALL
    # --------------------------------------------------------

    "start-all" {

        Start-All
    }


    # --------------------------------------------------------
    # STOP ALL
    # --------------------------------------------------------

    "stop-all" {

        Stop-All
    }


    # --------------------------------------------------------
    # STATUS ALL
    # --------------------------------------------------------

    "status-all" {

        Show-Status-All
    }


    # --------------------------------------------------------
    # LIST
    # --------------------------------------------------------

    "list" {

        Show-AllVMs
    }


    # --------------------------------------------------------
    # HELP
    # --------------------------------------------------------

    "help" {

        Show-Help
    }


    # --------------------------------------------------------
    # UNKNOWN COMMAND
    # --------------------------------------------------------

    default {

        Write-Host ""
        Write-Host "Unknown command: $Action" -ForegroundColor Red
        Write-Host ""

        Show-Help

        exit 1
    }
}