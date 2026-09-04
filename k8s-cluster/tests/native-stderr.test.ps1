<#
Regression test for the failure that killed `.\vms.ps1 -Masters 1 -Workers 3`
on its very first clone.

vms.ps1 sets $ErrorActionPreference = 'Stop'. In Windows PowerShell 5.1,
merging a native command's stderr with 2>&1 wraps each line in an ErrorRecord,
and under 'Stop' the first one becomes a terminating NativeCommandError. Every
poll of a node that has not finished booting prints "Connection refused" or
"Connection timed out" on ssh's stderr -- so Wait-Ssh threw on attempt one
instead of waiting, and Invoke-SshLive did the same to the apt upgrade, which
talks on stderr while succeeding. Stderr and the exit code are independent;
only the exit code means failure.

Nothing is cloned and no VM is touched: ssh and VBoxManage are stubbed.
  usage:  powershell -NoProfile -File tests\native-stderr.test.ps1
#>
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("vms-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {

$script:pass = 0; $script:fail = 0
function Check { param($Name, $Got, $Want)
    if ("$Got" -eq "$Want") { Write-Host "  PASS $Name"; $script:pass++ }
    else { Write-Host "  FAIL $Name (want '$Want', got '$Got')" -ForegroundColor Red; $script:fail++ }
}

# A real native process standing in for ssh.exe and VBoxManage.exe: it says its
# piece on stderr, then exits with whatever it was told to. A .cmd and not a
# .ps1 on purpose -- only a genuine child process raises NativeCommandError,
# which is the thing under test.
$stub = Join-Path $work 'noisy.cmd'
@'
@echo off
if "%STUB_CODE%"=="" set STUB_CODE=0
echo ssh: %STUB_SAY% 1>&2
if "%STUB_CODE%"=="0" echo ready
exit /b %STUB_CODE%
'@ | Set-Content -Path $stub -Encoding ASCII

function ssh { & $stub @args }        # shadows ssh.exe for the lifted helpers
$SshUser = 'ubuntu'; $SshKey = ''
$script:VBM = $stub

# Lift the helpers out of vms.ps1 itself, so a copy that drifts fails here.
$src = Get-Content (Join-Path $repo 'vms.ps1') -Raw
foreach ($fn in 'Get-SshArgs', 'Invoke-Ssh', 'Invoke-SshLive', 'Wait-Ssh', 'Invoke-VBox') {
    $m = [regex]::Match($src, "(?ms)^function\s+$fn\s*\{.*?^\}")
    if (-not $m.Success) { throw "could not lift $fn out of vms.ps1" }
    . ([scriptblock]::Create($m.Value))
}

$ErrorActionPreference = 'Stop'       # exactly as vms.ps1 runs

Write-Host "`n== the trap is real"
$env:STUB_CODE = '255'; $env:STUB_SAY = 'connect to host 192.168.1.190 port 22: Connection refused'
$threw = 'no'
try { $x = & $stub 2>&1 } catch { $threw = $_.FullyQualifiedErrorId }
Check "an unguarded 2>&1 still throws on stderr" $threw 'NativeCommandError'

Write-Host "`n== Wait-Ssh polls through the refusals instead of dying on the first"
$sw = [Diagnostics.Stopwatch]::StartNew()
$got = 'no error'
try { Wait-Ssh -Ip '10.255.255.1' -TimeoutSec 6 -What 'a node that never comes up' }
catch { $got = $(if ($_.Exception.Message -match 'timed out after 6s') { 'timeout' } else { $_.FullyQualifiedErrorId }) }
$sw.Stop()
Check "gives up with its own timeout, not NativeCommandError" $got 'timeout'
Check "and only after actually waiting"  ($sw.Elapsed.TotalSeconds -ge 5) 'True'

Write-Host "`n== a refused key stops the wait at once, instead of timing out on it"
$env:STUB_CODE = '255'; $env:STUB_SAY = 'ubuntu@1.2.3.4: Permission denied (publickey,password)'
$sw = [Diagnostics.Stopwatch]::StartNew()
$e = 'did not throw'
try { Wait-Ssh -Ip '1.2.3.4' -TimeoutSec 60 -What 'master-1' } catch { $e = $_.Exception.Message }
$sw.Stop()
Check "says the key was refused, not that it timed out" ($e -match 'refused the key')     'True'
Check "quotes what sshd actually said"                  ($e -match 'Permission denied')   'True'
Check "names the file that needs the key"               ($e -match 'authorized_keys')     'True'
Check "and does not sit out the timeout"                ($sw.Elapsed.TotalSeconds -lt 15) 'True'

Write-Host "`n== the plain timeout now carries the last ssh error"
$env:STUB_CODE = '255'; $env:STUB_SAY = 'connect to host 10.255.255.1 port 22: Connection refused'
$e = 'did not throw'
try { Wait-Ssh -Ip '10.255.255.1' -TimeoutSec 6 } catch { $e = $_.Exception.Message }
Check "still reports the timeout"  ($e -match 'timed out after 6s') 'True'
Check "with ssh's own last words"  ($e -match 'Connection refused') 'True'

Write-Host "`n== Wait-Ssh still returns the moment the node answers"
$env:STUB_CODE = '0'; $env:STUB_SAY = 'some harmless warning'
Check "returns true on 'ready' despite stderr" (Wait-Ssh -Ip '1.2.3.4' -TimeoutSec 10) 'True'

Write-Host "`n== Invoke-Ssh: stderr is captured, the exit code decides"
$out = (Invoke-Ssh -Ip '1.2.3.4' -Command 'hostname' | ForEach-Object { "$_" }) -join ' '
Check "stdout came back"        ($out -match 'ready')                'True'
Check "stderr came back too"    ($out -match 'harmless warning')     'True'

Write-Host "`n== a CRLF here-string is normalised before it reaches bash"
# vms.ps1 is saved CRLF, so its here-strings carry CRLF. bash does not treat
# \r as whitespace: a heredoc terminator reads as "EOF\r", never matches its
# "EOF", and swallows the rest of the script -- which is how chmod, netplan
# generate and netplan apply silently never ran.
$env:STUB_CODE = '0'; $env:STUB_SAY = 'fine'
$script:sentArgs = $null
function ssh { $script:sentArgs = $args; & $stub }
$crlf = "set -e`r`nsudo tee /etc/netplan/99-k8s.yaml <<EOF`r`nnetwork:`r`nEOF`r`n"
Invoke-Ssh -Ip '1.2.3.4' -Command $crlf -IgnoreExit | Out-Null
$sent = "$($script:sentArgs[-1])"
Check "no carriage return survives"      ($sent -match "`r")              'False'
Check "the heredoc terminator is bare"   ($sent -match "(?m)^EOF$")       'True'
Check "line structure is preserved"      (($sent -split "`n").Count -ge 4) 'True'
function ssh { & $stub @args }   # restore the plain stub

Write-Host "`n== Invoke-SshLive: a chatty-but-successful apt upgrade is not an error"
$threw = 'no'
try { Invoke-SshLive -Ip '1.2.3.4' -Command 'apt-get upgrade' } catch { $threw = $_.FullyQualifiedErrorId }
Check "survives stderr chatter on exit 0" $threw 'no'

Write-Host "`n== a real failure is still a failure, and still says why"
$env:STUB_CODE = '1'; $env:STUB_SAY = 'VBoxManage: error: Machine settings file already exists'
$e = 'did not throw'
try { Invoke-VBox clonevm k8s-base --name k8s-master-1 } catch { $e = $_.Exception.Message }
Check "Invoke-VBox raises its own error" ($e -match 'VBoxManage clonevm k8s-base .* failed') 'True'
Check "quoting what VBoxManage said"     ($e -match 'settings file already exists')          'True'
$e = 'did not throw'
try { Invoke-Ssh -Ip '1.2.3.4' -Command 'hostname' } catch { $e = $_.Exception.Message }
Check "Invoke-Ssh raises its own error"  ($e -match 'ssh ubuntu@1\.2\.3\.4 failed')          'True'

Write-Host "`n  $script:pass passed, $script:fail failed`n"
exit $(if ($script:fail) { 1 } else { 0 })

} finally {
    Remove-Item Env:STUB_CODE, Env:STUB_SAY -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
