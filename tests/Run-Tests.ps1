# Dependency-free test runner for Enviro Easy.  Usage:  powershell -File tests\Run-Tests.ps1
# Everything that touches the registry runs against a throw-away key under
# HKCU:\Software\EnviroEasyTest - your real PATH is never read or written.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\EnviroEasy.ps1')

$script:pass = 0
$script:fail = 0

function Assert-True {
    param($Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  pass  $Message" -ForegroundColor DarkGreen }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $ok = ("$Actual" -ceq "$Expected")
    Assert-True $ok "$Message$(if (-not $ok) { "  (expected '$Expected', got '$Actual')" })"
}

# ---------------------------------------------------------------- pure helpers
Write-Host "`nHelpers" -ForegroundColor Cyan
Assert-Equal (ConvertTo-NormalPath 'C:\Foo\Bar\') 'C:\Foo\Bar' 'trailing slash is trimmed'
Assert-Equal (ConvertTo-NormalPath '"C:\Foo"') 'C:\Foo' 'quotes are trimmed'
Assert-Equal (ConvertTo-NormalPath 'C:\') 'C:\' 'drive root is kept'
Assert-Equal (ConvertTo-NormalPath '%SystemRoot%\System32') "$env:SystemRoot\System32" '%VARS% are expanded for comparison'
Assert-Equal (Get-VersionKey 'Python312') '3.12' 'Python312 -> 3.12'
Assert-Equal (Get-VersionKey 'Python39') '3.9' 'Python39 -> 3.9'
Assert-Equal (Get-VersionKey 'jdk-21.0.2') '21.0.2' 'jdk-21.0.2 -> 21.0.2'
Assert-True ((Get-VersionKey 'jdk-21.0.2') -gt (Get-VersionKey 'jdk1.8.0_301')) 'JDK 21 sorts above JDK 8'
Assert-True ((Get-VersionKey 'Python313') -gt (Get-VersionKey 'Python39')) 'Python313 sorts above Python39'
Assert-Equal (Get-VersionKey 'jbr') '0.0' 'no version -> 0.0'
Assert-Equal @(Split-PathList 'a;;b; ;c').Count 3 'empty PATH segments are dropped'

Write-Host "`nAdd-PathEntries" -ForegroundColor Cyan
$r = Add-PathEntries -Current @('C:\a', '%USERPROFILE%\bin') -Effective @('C:\a', "$env:USERPROFILE\bin") -Wanted @('C:\a\', 'C:\NEW')
Assert-Equal ($r.Added -join '|') 'C:\NEW' 'duplicates (any case / trailing slash) are skipped'
Assert-Equal ($r.List -join '|') 'C:\a|%USERPROFILE%\bin|C:\NEW' '%VAR% entries are preserved verbatim'
$r = Add-PathEntries -Current @('C:\a') -Effective @('C:\a', 'C:\b') -Wanted @('c:\B')
Assert-Equal $r.Added.Count 0 'entry already in the OTHER scope is not added'
$r = Add-PathEntries -Current @('C:\a', '%USERPROFILE%\AppData\Local\Microsoft\WindowsApps', 'C:\z') -Effective @() -Wanted @('C:\py', 'C:\py\Scripts')
Assert-Equal ($r.List -join '|') 'C:\a|C:\py|C:\py\Scripts|%USERPROFILE%\AppData\Local\Microsoft\WindowsApps|C:\z' 'new folders go before the WindowsApps Store stub'
$r = Add-PathEntries -Current @() -Effective @() -Wanted @('C:\x')
Assert-Equal ($r.List -join '|') 'C:\x' 'works with an empty PATH'
$r = Add-PathEntries -Current @('C:\a') -Effective @('C:\a') -Wanted @('C:\x', 'C:\X')
Assert-Equal $r.Added.Count 1 'the same folder twice in one run is added once'

Write-Host "`nTool catalogue" -ForegroundColor Cyan
foreach ($t in $script:Tools) {
    Assert-True ($t.Key -and $t.Name -and $t.Marker -and $t.Bins.Count -gt 0 -and $t.Verify.Count -gt 0) "$($t.Key) spec is complete"
    Assert-True ($t.Verify -notmatch '^\s') "$($t.Key) verify commands are well formed"
}
Assert-Equal @($script:Tools | Select-Object -ExpandProperty Key -Unique).Count $script:Tools.Count 'tool keys are unique'
$validKeys = (Get-Command (Join-Path $PSScriptRoot '..\EnviroEasy.ps1')).Parameters['Tool'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues }
foreach ($t in $script:Tools) { Assert-True ($validKeys -contains $t.Key) "-Tool accepts '$($t.Key)'" }

# ---------------------------------------------------- end-to-end on a fake registry
Write-Host "`nEnd to end (sandbox registry key + fake installs)" -ForegroundColor Cyan
$id = [guid]::NewGuid().ToString('N')
$testKeyPath = "Software\EnviroEasyTest\$id"
$script:TestKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testKeyPath)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "EnviroEasyTest-$id"
$script:BackupDir = Join-Path $sandbox 'backups'

function New-Fake {
    param([string]$RelPath)
    $full = Join-Path $sandbox $RelPath
    [void](New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force)
    Set-Content -LiteralPath $full -Value ''
    return $full
}

try {
    # A "non-default location" for every tool, registered only through env vars.
    [void](New-Fake 'My Tools\node-v20\node.exe')
    [void](New-Fake 'D-drive\Python313\python.exe')
    [void](New-Fake 'D-drive\Python313\Scripts\pip.exe')
    [void](New-Fake 'Git Custom\cmd\git.exe')
    [void](New-Fake 'jdk-21\bin\javac.exe')
    [void](New-Fake 'android sdk\platform-tools\adb.exe')
    [void](New-Fake 'android sdk\emulator\emulator.exe')
    [void](New-Fake 'android sdk\cmdline-tools\latest\bin\sdkmanager.bat')
    [void](New-Fake 'flutter\bin\flutter.bat')
    [void](New-Fake 'maven\bin\mvn.cmd')
    [void](New-Fake 'gradle\bin\gradle.bat')

    $userProfileBin = '%USERPROFILE%\bin'
    $originalPath = "$userProfileBin;C:\SomethingExisting"
    $kExpand = [Microsoft.Win32.RegistryValueKind]::ExpandString
    $script:TestKey.SetValue('Path', $originalPath, $kExpand)
    $script:TestKey.SetValue('NVM_SYMLINK', (Join-Path $sandbox 'My Tools\node-v20'))
    $script:TestKey.SetValue('PYTHONHOME', (Join-Path $sandbox 'D-drive\Python313'))
    $script:TestKey.SetValue('GIT_INSTALL_ROOT', (Join-Path $sandbox 'Git Custom'))
    $script:TestKey.SetValue('JAVA_HOME', (Join-Path $sandbox 'jdk-21'))
    $script:TestKey.SetValue('ANDROID_SDK_ROOT', (Join-Path $sandbox 'android sdk'))   # only the OLD name is set
    $script:TestKey.SetValue('FLUTTER_ROOT', (Join-Path $sandbox 'flutter'))
    $script:TestKey.SetValue('MAVEN_HOME', (Join-Path $sandbox 'maven'))
    $script:TestKey.SetValue('GRADLE_HOME', (Join-Path $sandbox 'gradle'))

    # --- dry run changes nothing
    Invoke-EnviroEasy -Scope User -DryRun 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $originalPath 'dry run leaves PATH untouched'
    Assert-True ($null -eq (Get-EnvRaw User 'ANDROID_HOME').Value) 'dry run does not create ANDROID_HOME'
    Assert-True (-not (Test-Path (Get-BackupDir))) 'dry run writes no backup'

    # --- real run
    Invoke-EnviroEasy -Scope User 6>$null
    $after = Get-EnvRaw User 'Path'
    $entries = @(Split-PathList $after.Value)
    Assert-Equal $entries[0] $userProfileBin 'existing %VAR% entry is preserved verbatim, in place'
    Assert-Equal $entries[1] 'C:\SomethingExisting' 'existing entries keep their order'
    Assert-Equal $after.Kind 'ExpandString' 'PATH stays REG_EXPAND_SZ'
    foreach ($rel in 'My Tools\node-v20', 'D-drive\Python313', 'D-drive\Python313\Scripts', 'Git Custom\cmd', 'jdk-21\bin',
                     'android sdk\platform-tools', 'android sdk\emulator', 'android sdk\cmdline-tools\latest\bin', 'flutter\bin', 'maven\bin', 'gradle\bin') {
        Assert-True ($entries -contains (Join-Path $sandbox $rel)) "PATH now contains ...\$rel"
    }
    Assert-Equal (Get-EnvRaw User 'ANDROID_HOME').Value (Join-Path $sandbox 'android sdk') 'ANDROID_HOME is set from the old ANDROID_SDK_ROOT'
    Assert-Equal (Get-EnvRaw User 'JAVA_HOME').Value (Join-Path $sandbox 'jdk-21') 'a valid JAVA_HOME is left alone'
    $backups = @(Get-ChildItem (Get-BackupDir) -Filter 'backup-User-*.json')
    Assert-Equal $backups.Count 1 'exactly one backup was written'

    # --- second run is a no-op
    Invoke-EnviroEasy -Scope User 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $after.Value 'second run changes nothing (idempotent)'
    Assert-Equal @(Get-ChildItem (Get-BackupDir) -Filter 'backup-User-*.json').Count 1 'no-op run writes no extra backup'

    # --- -Tool filter
    $script:TestKey.SetValue('Path', $originalPath, $kExpand)
    Invoke-EnviroEasy -Scope User -Tool Java 6>$null
    $onlyJava = @(Split-PathList (Get-EnvRaw User 'Path').Value)
    Assert-Equal $onlyJava.Count 3 '-Tool Java adds only the Java folder'

    # --- restore
    Invoke-EnviroEasy -Scope User -Restore 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $originalPath 'restore puts PATH back exactly'

    # restore after the full run: new variable must disappear again
    $script:TestKey.SetValue('Path', $originalPath, $kExpand)
    $script:TestKey.DeleteValue('ANDROID_HOME', $false)
    Invoke-EnviroEasy -Scope User 6>$null
    Assert-True ($null -ne (Get-EnvRaw User 'ANDROID_HOME').Value) 'ANDROID_HOME exists after apply'
    Invoke-EnviroEasy -Scope User -Restore 6>$null
    Assert-True ($null -eq (Get-EnvRaw User 'ANDROID_HOME').Value) 'restore removes variables that did not exist before'
    Assert-Equal (Get-EnvRaw User 'Path').Value $originalPath 'restore puts PATH back after a full run'

    # --- restore with nothing to restore is a clean error
    Remove-Item (Get-BackupDir) -Recurse -Force
    $threw = $false
    try { Invoke-EnviroEasy -Scope User -Restore 6>$null } catch { $threw = $true }
    Assert-True $threw 'restore without a backup fails with an error'
}
finally {
    $script:TestKey.Close()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKeyPath, $false)
    $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\EnviroEasyTest', $true)
    if ($parent) {
        $empty = ($parent.SubKeyCount -eq 0)
        $parent.Close()
        if ($empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\EnviroEasyTest', $false) }
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    $script:TestKey = $null
}

Write-Host ''
$color = if ($script:fail) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $color
if ($script:fail) { exit 1 }
exit 0
