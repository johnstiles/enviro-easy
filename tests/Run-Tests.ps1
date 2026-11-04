# Dependency-free test runner for Enviro Easy.  Usage:  powershell -File tests\Run-Tests.ps1
#
# Safety: everything that touches the registry runs against throw-away keys under
# HKCU:\Software\EnviroEasyTest, and the PowerShell execution policy functions are replaced
# by in-memory fakes. Your real PATH, variables and execution policy are never read or written.

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

# ---- fake execution policy (replaces the real functions for the whole run) ----
$script:FakePolicy = @{ MachinePolicy = 'Undefined'; UserPolicy = 'Undefined'; Process = 'Bypass'; CurrentUser = 'Undefined'; LocalMachine = 'Undefined' }
function Get-PolicyList {
    return @('MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine' |
        ForEach-Object { [pscustomobject]@{ Scope = $_; ExecutionPolicy = $script:FakePolicy[$_] } })
}
function Set-PolicyValue { param([string]$PolicyScope, [string]$Policy) $script:FakePolicy[$PolicyScope] = $Policy }
function Reset-FakePolicy { foreach ($k in @($script:FakePolicy.Keys)) { if ($k -ne 'Process') { $script:FakePolicy[$k] = 'Undefined' } } }

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
Assert-Equal (@(Resolve-Scopes 'Both') -join ',') 'Machine,User' 'Both = System then User'
Assert-Equal (@(Resolve-Scopes 'User') -join ',') 'User' 'User scope'
Assert-Equal (@(Resolve-Scopes 'Machine') -join ',') 'Machine' 'Machine scope'

Write-Host "`nAdd-PathEntries" -ForegroundColor Cyan
$r = Add-PathEntries -Current @('C:\a', '%USERPROFILE%\bin') -Effective @('C:\a', "$env:USERPROFILE\bin") -Wanted @('C:\a\', 'C:\NEW')
Assert-Equal ($r.Added -join '|') 'C:\NEW' 'duplicates (any case / trailing slash) are skipped'
Assert-Equal ($r.List -join '|') 'C:\a|%USERPROFILE%\bin|C:\NEW' '%VAR% entries are preserved verbatim'
$r = Add-PathEntries -Current @('C:\a') -Effective @('C:\a', 'C:\b') -Wanted @('c:\B')
Assert-Equal $r.Added.Count 0 'entry already in the Effective set is not added'
$r = Add-PathEntries -Current @('C:\a', '%USERPROFILE%\AppData\Local\Microsoft\WindowsApps', 'C:\z') -Effective @() -Wanted @('C:\py', 'C:\py\Scripts')
Assert-Equal ($r.List -join '|') 'C:\a|C:\py|C:\py\Scripts|%USERPROFILE%\AppData\Local\Microsoft\WindowsApps|C:\z' 'new folders go before the WindowsApps Store stub'
$r = Add-PathEntries -Current @() -Effective @() -Wanted @('C:\x')
Assert-Equal ($r.List -join '|') 'C:\x' 'works with an empty PATH'
$r = Add-PathEntries -Current @('C:\a') -Effective @('C:\a') -Wanted @('C:\x', 'C:\X')
Assert-Equal $r.Added.Count 1 'the same folder twice in one run is added once'

Write-Host "`nTool selection (-Tool)" -ForegroundColor Cyan
Assert-Equal @(Resolve-ToolSelection 'All').Count $script:Tools.Count "'All' selects every tool"
Assert-Equal ((@(Resolve-ToolSelection 'Java,Android') | ForEach-Object { $_.Key }) -join ',') 'Java,Android' 'a comma list arriving as ONE string (as with -File) works'
Assert-Equal ((@(Resolve-ToolSelection @('java', 'ANDROID')) | ForEach-Object { $_.Key }) -join ',') 'Java,Android' 'case does not matter'
Assert-Equal ((@(Resolve-ToolSelection 'npm,pip,jdk') | ForEach-Object { $_.Key }) -join ',') 'Node,Python,Java' 'aliases npm / pip / jdk work'
Assert-Equal @(Resolve-ToolSelection 'Java,java').Count 1 'duplicates are collapsed'
$threw = $false; try { Resolve-ToolSelection 'Java,Nope' | Out-Null } catch { $threw = $true }
Assert-True $threw 'an unknown tool name is an error'

Write-Host "`nTool catalogue" -ForegroundColor Cyan
foreach ($t in $script:Tools) {
    Assert-True ($t.Key -and $t.Name -and $t.Label -and $t.Marker -and $t.Bins.Count -gt 0 -and $t.Verify.Count -gt 0) "$($t.Key) spec is complete"
}
Assert-Equal @($script:Tools | Select-Object -ExpandProperty Key -Unique).Count $script:Tools.Count 'tool keys are unique'
Assert-True (@($script:Tools | Where-Object { $_.Key -eq 'Node' }).CreateDirs -contains '%APPDATA%\npm') 'Node creates %APPDATA%\npm when missing'

Write-Host "`nPowerShell execution policy (npm.ps1)" -ForegroundColor Cyan
function New-List { param([hashtable]$Overrides) $h = @{ MachinePolicy = 'Undefined'; UserPolicy = 'Undefined'; Process = 'Bypass'; CurrentUser = 'Undefined'; LocalMachine = 'Undefined' }; foreach ($k in $Overrides.Keys) { $h[$k] = $Overrides[$k] }; return @($h.Keys | ForEach-Object { [pscustomobject]@{ Scope = $_; ExecutionPolicy = $h[$_] } }) }
$p = Get-PolicyPlan -Scopes @('Machine', 'User') -List (New-List @{})
Assert-True $p.State.Blocking 'everything Undefined = Restricted = blocking'
Assert-Equal $p.State.Source 'Default' 'source is the Windows default'
Assert-Equal ((@($p.Targets) | ForEach-Object { $_.PolicyScope } | Sort-Object) -join ',') 'CurrentUser,LocalMachine' 'Both scopes -> fixes CurrentUser and LocalMachine'
Assert-True (-not $p.StillBlockedAfter) 'plan unblocks npm'
$p = Get-PolicyPlan -Scopes @('User') -List (New-List @{})
Assert-Equal ((@($p.Targets) | ForEach-Object { $_.PolicyScope }) -join ',') 'CurrentUser' 'User scope -> only CurrentUser'
$p = Get-PolicyPlan -Scopes @('Machine', 'User') -List (New-List @{ CurrentUser = 'RemoteSigned' })
Assert-True (-not $p.State.Blocking) 'RemoteSigned is not blocking'
Assert-Equal @($p.Targets).Count 0 'nothing to change when RemoteSigned already applies'
$p = Get-PolicyPlan -Scopes @('User') -List (New-List @{ LocalMachine = 'Unrestricted' })
Assert-Equal @($p.Targets).Count 0 'Unrestricted at machine level is left alone'
$p = Get-PolicyPlan -Scopes @('Machine', 'User') -List (New-List @{ MachinePolicy = 'Restricted' })
Assert-True ($p.State.Blocking -and $p.State.Gpo) 'a Group Policy block is detected'
Assert-Equal @($p.Targets).Count 0 'a Group Policy block is never "fixed"'
$p = Get-PolicyPlan -Scopes @('User') -List (New-List @{ CurrentUser = 'AllSigned' })
Assert-True $p.State.Blocking 'AllSigned blocks npm.ps1'
Assert-Equal $p.Targets[0].Previous 'AllSigned' 'previous value is remembered for undo'
$p = Get-PolicyPlan -Scopes @('Machine') -List (New-List @{ CurrentUser = 'Restricted' })
Assert-Equal ((@($p.Targets) | ForEach-Object { $_.PolicyScope } | Sort-Object) -join ',') 'CurrentUser,LocalMachine' 'an explicit CurrentUser=Restricted is fixed even for a Machine-only run'
Assert-True (-not $p.StillBlockedAfter) '... and npm ends up unblocked'

Write-Host "`nRelaunch arguments (administrator window)" -ForegroundColor Cyan
$a = Format-RelaunchArguments -ScriptPath 'C:\a b\EnviroEasy.ps1' -Scope 'Both' -ToolKeys @('Java', 'Android') -Search 'C' -AllVersions $true -Force $false -SkipPolicy $false -Yes $false -Restore $false -BackupFile ''
Assert-True ($a -match '-File "C:\\a b\\EnviroEasy\.ps1"') 'script path with spaces is quoted'
Assert-True ($a -match '-Tool Java,Android') 'tools are passed as ONE comma list'
Assert-True ($a -match '-Scope Both -Search C') 'scope and search are passed'
Assert-True ($a -match '-AllVersions' -and $a -notmatch '-Force' -and $a -match '-Elevated$') 'switches are passed only when set; -Elevated is last'

Write-Host "`nInteractive menu and prompts (Read-Host is mocked)" -ForegroundColor Cyan
$script:answers = New-Object System.Collections.Queue
function Read-Host { param([string]$Prompt) return [string]$script:answers.Dequeue() }
function Set-Answers { param([string[]]$a) $script:answers.Clear(); foreach ($x in $a) { $script:answers.Enqueue($x) } }

Set-Answers '1', 'A', '1', '1'
$m = Show-MainMenu 6>$null
Assert-True ($m.Scope -eq 'Both' -and $m.Search -eq 'Common' -and $m.Tool.Count -eq $script:Tools.Count -and -not $m.ContainsKey('DryRun')) 'menu: set up, all tools, common folders, System + User'
Set-Answers '', '', '', ''
$m = Show-MainMenu 6>$null
Assert-True ($m.Scope -eq 'Both' -and $m.Search -eq 'Common') 'menu: pressing Enter four times picks the recommended answers'
Set-Answers '2', 'P', '1,4', '2', '2'
$m = Show-MainMenu 6>$null
Assert-True ($m.DryRun -and $m.Scope -eq 'User' -and $m.Search -eq 'C' -and ($m.Tool -join ',') -eq 'Node,Java') 'menu: preview, picked tools 1,4 = Node+Java, search C:, User only'
Set-Answers '3'
Assert-True ((Show-MainMenu 6>$null).Restore) 'menu: undo'
Set-Answers 'q'
Assert-True ($null -eq (Show-MainMenu 6>$null)) 'menu: quit'
Set-Answers 'x', '10', '0', '2,3'
Assert-Equal ((@(Show-ToolPicker 6>$null) | ForEach-Object { $_.Key }) -join ',') 'Python,Git' 'picker: bad input is rejected and asked again'
Set-Answers 'a'
Assert-Equal @(Show-ToolPicker 6>$null).Count $script:Tools.Count 'picker: A = all tools'
$java = $script:Tools | Where-Object { $_.Key -eq 'Java' }
$cands = @('C:\jdk-21', 'C:\jdk-17', 'D:\jdk-11')
Set-Answers ''
Assert-Equal ((Select-Candidates -Tool $java -Candidates $cands 6>$null) -join '|') 'C:\jdk-21' 'candidates: Enter = best match'
Set-Answers '2'
Assert-Equal ((Select-Candidates -Tool $java -Candidates $cands 6>$null) -join '|') 'C:\jdk-17' 'candidates: pick the second'
Set-Answers 'a'
Assert-Equal @(Select-Candidates -Tool $java -Candidates $cands 6>$null).Count 3 'candidates: A = all'
Set-Answers 's'
Assert-Equal @(Select-Candidates -Tool $java -Candidates $cands 6>$null).Count 0 'candidates: S = skip'
Set-Answers 'nope', '7', '3'
Assert-Equal ((Select-Candidates -Tool $java -Candidates $cands 6>$null) -join '|') 'D:\jdk-11' 'candidates: invalid answers are asked again'
Remove-Item Function:\Read-Host

Write-Host "`nAdministrator relaunch (real child process, path with spaces)" -ForegroundColor Cyan
$selfPath = (Resolve-Path (Join-Path $PSScriptRoot '..\EnviroEasy.ps1')).Path
$relaunch = Format-RelaunchArguments -ScriptPath $selfPath -Scope 'User' -ToolKeys @('Java', 'Android') -Search 'Common' -AllVersions $false -Force $false -SkipPolicy $true -Yes $true -Restore $false -BackupFile ''
$outFile = Join-Path ([IO.Path]::GetTempPath()) ("enviro-relaunch-{0}.txt" -f [guid]::NewGuid().ToString('N'))
$proc = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ($relaunch + ' -DryRun') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile
$text = Get-Content -LiteralPath $outFile -Raw
Remove-Item -LiteralPath $outFile -Force
Assert-Equal $proc.ExitCode 0 'the exact argument string runs the script and exits 0'
Assert-True ($text -match 'DRY RUN' -and $text -match 'Java JDK|Android') 'the child honored -Tool Java,Android and -DryRun'
Assert-True ($text -notmatch 'Node\.js') 'the child did not look for tools that were not requested'

# ----------------------------------------------------------- sandbox for the rest
$id = [guid]::NewGuid().ToString('N')
$testRoot = "Software\EnviroEasyTest\$id"
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "EnviroEasyTest-$id"
$script:BackupDir = Join-Path $sandbox 'backups'
$realAppData = $env:APPDATA
$keyUser = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$testRoot\User")
$keyMachine = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$testRoot\Machine")
$script:TestKeys = @{ User = $keyUser; Machine = $keyMachine }
$env:APPDATA = Join-Path $sandbox 'AppData'
[void](New-Item -ItemType Directory -Path $env:APPDATA -Force)

function New-Fake {
    param([string]$RelPath)
    $full = Join-Path $sandbox $RelPath
    [void](New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force)
    Set-Content -LiteralPath $full -Value ''
    return $full
}
function Clear-Keys {
    foreach ($k in @($keyUser, $keyMachine)) { foreach ($n in $k.GetValueNames()) { $k.DeleteValue($n) } }
}

try {
    # ------------------------------------------------------------ deep drive search
    Write-Host "`nDeep drive search" -ForegroundColor Cyan
    [void](New-Fake 'deep\Tools\node-v20\node.exe')
    [void](New-Fake 'deep\py\Python312\python.exe')
    [void](New-Fake 'deep\proj\venv\Scripts\python.exe')
    Set-Content -LiteralPath (Join-Path $sandbox 'deep\proj\venv\pyvenv.cfg') -Value 'home = x'
    [void](New-Fake 'deep\proj\node_modules\.bin\node.exe')
    [void](New-Fake 'deep\jdk-17\bin\javac.exe')
    [void](New-Fake 'deep\IDE\jbr\bin\javac.exe')
    [void](New-Fake 'deep\flutter\bin\flutter.bat')
    [void](New-Fake 'deep\flutter\bin\cache\dart-sdk\bin\dart.exe')
    [void](New-Fake 'deep\Git X\cmd\git.exe')
    [void](New-Fake 'deep\Some Drive\Android\platform-tools\adb.exe')
    [void](New-Fake 'deep\mvn\bin\mvn.cmd')

    $found = Invoke-DeepScan -Roots @((Join-Path $sandbox 'deep')) -Tools $script:Tools -Quiet $true
    $deepRoot = Join-Path $sandbox 'deep'
    Assert-Equal (@($found['Node']).Path -join '|') (Join-Path $deepRoot 'Tools\node-v20') 'finds node.exe in an unusual folder (and skips node_modules)'
    Assert-Equal (@($found['Python']).Path -join '|') (Join-Path $deepRoot 'py\Python312') 'finds the real Python and ignores the virtual environment'
    $java = @($found['Java'])
    Assert-Equal $java.Count 2 'finds both JDKs'
    Assert-Equal (($java | Where-Object { $_.Path -match 'jdk-17' }).Rank) 2 'a normal JDK has priority 2'
    Assert-Equal (($java | Where-Object { $_.Path -match 'jbr' }).Rank) 3 'a JDK bundled inside an IDE has the lowest priority'
    Assert-Equal (@($found['Flutter']).Path -join '|') (Join-Path $deepRoot 'flutter') 'finds Flutter'
    Assert-Equal @($found['Dart']).Count 0 "ignores the Dart SDK that lives inside Flutter's cache"
    Assert-Equal (@($found['Git']).Path -join '|') (Join-Path $deepRoot 'Git X') 'finds Git (cmd\git.exe) and returns the install root'
    Assert-Equal (@($found['Android']).Path -join '|') (Join-Path $deepRoot 'Some Drive\Android') 'finds the Android SDK (platform-tools\adb.exe)'
    Assert-Equal (@($found['Maven']).Path -join '|') (Join-Path $deepRoot 'mvn') 'finds Maven'

    # ------------------------------------------------------------ end to end, both scopes
    Write-Host "`nEnd to end: System + User (sandbox registry + fake installs)" -ForegroundColor Cyan
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

    $userBin = '%USERPROFILE%\bin'
    $userOriginal = "$userBin;C:\UserExisting"
    $machineOriginal = '%SystemRoot%\system32;C:\MachineExisting'
    $kExpand = [Microsoft.Win32.RegistryValueKind]::ExpandString
    function Reset-E2E {
        Clear-Keys
        Reset-FakePolicy
        if (Test-Path $script:BackupDir) { Remove-Item $script:BackupDir -Recurse -Force }
        $keyUser.SetValue('Path', $userOriginal, $kExpand)
        $keyMachine.SetValue('Path', $machineOriginal, $kExpand)
        $keyUser.SetValue('NVM_SYMLINK', (Join-Path $sandbox 'My Tools\node-v20'))
        $keyUser.SetValue('PYTHONHOME', (Join-Path $sandbox 'D-drive\Python313'))
        $keyUser.SetValue('GIT_INSTALL_ROOT', (Join-Path $sandbox 'Git Custom'))
        $keyUser.SetValue('JAVA_HOME', (Join-Path $sandbox 'jdk-21'))
        $keyUser.SetValue('ANDROID_SDK_ROOT', (Join-Path $sandbox 'android sdk'))   # only the OLD name is set
        $keyUser.SetValue('FLUTTER_ROOT', (Join-Path $sandbox 'flutter'))
        $keyUser.SetValue('MAVEN_HOME', (Join-Path $sandbox 'maven'))
        $keyUser.SetValue('GRADLE_HOME', (Join-Path $sandbox 'gradle'))
    }
    Reset-E2E
    $npmDir = Join-Path $env:APPDATA 'npm'
    Assert-True (-not (Test-Path $npmDir)) 'precondition: the npm global folder does not exist yet'

    # --- dry run changes nothing
    Invoke-EnviroEasy -Scope Both -DryRun 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $userOriginal 'dry run leaves the User PATH untouched'
    Assert-Equal (Get-EnvRaw Machine 'Path').Value $machineOriginal 'dry run leaves the System PATH untouched'
    Assert-True ($null -eq (Get-EnvRaw User 'ANDROID_HOME').Value) 'dry run does not create ANDROID_HOME'
    Assert-Equal $script:FakePolicy['CurrentUser'] 'Undefined' 'dry run leaves the execution policy untouched'
    Assert-True (-not (Test-Path (Get-BackupDir))) 'dry run writes no backup'
    Assert-True (-not (Test-Path $npmDir)) 'dry run does not create the npm folder'

    # --- real run
    Invoke-EnviroEasy -Scope Both 6>$null
    $u = Get-EnvRaw User 'Path'; $m = Get-EnvRaw Machine 'Path'
    $uEntries = @(Split-PathList $u.Value); $mEntries = @(Split-PathList $m.Value)
    Assert-Equal $uEntries[0] $userBin 'User: existing %VAR% entry preserved verbatim, in place'
    Assert-Equal $mEntries[0] '%SystemRoot%\system32' 'System: existing %VAR% entry preserved verbatim, in place'
    Assert-Equal $u.Kind 'ExpandString' 'User PATH stays REG_EXPAND_SZ'
    Assert-Equal $m.Kind 'ExpandString' 'System PATH stays REG_EXPAND_SZ'
    foreach ($rel in 'My Tools\node-v20', 'D-drive\Python313', 'D-drive\Python313\Scripts', 'Git Custom\cmd', 'jdk-21\bin',
                     'android sdk\platform-tools', 'android sdk\emulator', 'android sdk\cmdline-tools\latest\bin', 'flutter\bin', 'maven\bin', 'gradle\bin') {
        $full = Join-Path $sandbox $rel
        Assert-True (($uEntries -contains $full) -and ($mEntries -contains $full)) "BOTH PATHs contain ...\$rel"
    }
    Assert-True (Test-Path $npmDir) 'the missing npm global folder was created'
    Assert-True ($uEntries -contains $npmDir) 'User PATH contains the npm global folder'
    Assert-True (-not ($mEntries -contains $npmDir)) 'System PATH does NOT contain the per-user npm folder'
    foreach ($s in 'User', 'Machine') {
        Assert-Equal (Get-EnvRaw $s 'ANDROID_HOME').Value (Join-Path $sandbox 'android sdk') "ANDROID_HOME set in $s from the old ANDROID_SDK_ROOT"
        Assert-Equal (Get-EnvRaw $s 'JAVA_HOME').Value (Join-Path $sandbox 'jdk-21') "JAVA_HOME set in $s"
    }
    Assert-Equal $script:FakePolicy['CurrentUser'] 'RemoteSigned' 'execution policy: CurrentUser -> RemoteSigned (npm works in PowerShell)'
    Assert-Equal $script:FakePolicy['LocalMachine'] 'RemoteSigned' 'execution policy: LocalMachine -> RemoteSigned'
    Assert-Equal $script:FakePolicy['Process'] 'Bypass' 'the Process scope is never touched'
    Assert-Equal @(Get-ChildItem (Get-BackupDir) -Filter 'backup-*.json').Count 2 'one backup per scope was written'

    # --- second run is a no-op
    $uAfter = (Get-EnvRaw User 'Path').Value; $mAfter = (Get-EnvRaw Machine 'Path').Value
    Invoke-EnviroEasy -Scope Both 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $uAfter 'second run changes nothing in User (idempotent)'
    Assert-Equal (Get-EnvRaw Machine 'Path').Value $mAfter 'second run changes nothing in System (idempotent)'
    Assert-Equal @(Get-ChildItem (Get-BackupDir) -Filter 'backup-*.json').Count 2 'a no-op run writes no extra backups'

    # --- restore (both scopes at once)
    Invoke-EnviroEasy -Scope Both -Restore 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $userOriginal 'restore: User PATH exactly as before'
    Assert-Equal (Get-EnvRaw Machine 'Path').Value $machineOriginal 'restore: System PATH exactly as before'
    Assert-True ($null -eq (Get-EnvRaw User 'ANDROID_HOME').Value -and $null -eq (Get-EnvRaw Machine 'ANDROID_HOME').Value) 'restore: variables that did not exist are removed'
    Assert-Equal (Get-EnvRaw User 'JAVA_HOME').Value (Join-Path $sandbox 'jdk-21') 'restore: a pre-existing variable keeps its value'
    Assert-Equal $script:FakePolicy['CurrentUser'] 'Undefined' 'restore: CurrentUser execution policy back to Undefined'
    Assert-Equal $script:FakePolicy['LocalMachine'] 'Undefined' 'restore: LocalMachine execution policy back to Undefined'

    # --- User only leaves System alone
    Reset-E2E
    Invoke-EnviroEasy -Scope User 6>$null
    Assert-Equal (Get-EnvRaw Machine 'Path').Value $machineOriginal '-Scope User: System PATH untouched'
    Assert-True ($null -eq (Get-EnvRaw Machine 'ANDROID_HOME').Value) '-Scope User: no System variables'
    Assert-Equal $script:FakePolicy['CurrentUser'] 'RemoteSigned' '-Scope User: CurrentUser policy fixed'
    Assert-Equal $script:FakePolicy['LocalMachine'] 'Undefined' '-Scope User: LocalMachine policy untouched'

    # --- Machine only
    Reset-E2E
    Invoke-EnviroEasy -Scope Machine 6>$null
    Assert-Equal (Get-EnvRaw User 'Path').Value $userOriginal '-Scope Machine: User PATH untouched'
    Assert-True (@(Split-PathList (Get-EnvRaw Machine 'Path').Value) -contains (Join-Path $sandbox 'jdk-21\bin')) '-Scope Machine: System PATH updated'

    # --- -SkipPolicy and -Tool
    Reset-E2E
    Invoke-EnviroEasy -Scope Both -SkipPolicy 6>$null
    Assert-Equal $script:FakePolicy['CurrentUser'] 'Undefined' '-SkipPolicy leaves the execution policy alone'
    Reset-E2E
    Invoke-EnviroEasy -Scope Both -Tool 'Java' 6>$null
    Assert-Equal @(Split-PathList (Get-EnvRaw Machine 'Path').Value).Count 3 '-Tool Java adds only the Java folder to System'
    Assert-Equal $script:FakePolicy['CurrentUser'] 'Undefined' 'no Node selected = execution policy not touched'

    # --- a policy forced by the organization is reported, never overridden
    Reset-E2E
    $script:FakePolicy['MachinePolicy'] = 'AllSigned'
    Invoke-EnviroEasy -Scope Both 6>$null
    Assert-Equal $script:FakePolicy['CurrentUser'] 'Undefined' 'a Group Policy execution policy is left alone'
    $script:FakePolicy['MachinePolicy'] = 'Undefined'

    # --- deep search end to end (drives are faked to the sandbox; -AllVersions so the result does not depend on this PC)
    Reset-E2E
    $keyUser.DeleteValue('MAVEN_HOME'); $keyUser.DeleteValue('FLUTTER_ROOT')
    function Get-FixedDrives { return @((Join-Path $sandbox 'deep') + '\') }
    Invoke-EnviroEasy -Scope User -Search All -Tool 'Maven,Flutter' -AllVersions -SkipPolicy 6>$null
    $uDeep = @(Split-PathList (Get-EnvRaw User 'Path').Value)
    Assert-True ($uDeep -contains (Join-Path $sandbox 'deep\mvn\bin')) 'deep search found Maven in an unusual folder and put it on PATH'
    Assert-True ($uDeep -contains (Join-Path $sandbox 'deep\flutter\bin')) 'deep search found Flutter in an unusual folder and put it on PATH'

    # --- restore with nothing to restore is a clean error
    Remove-Item (Get-BackupDir) -Recurse -Force
    $threw = $false
    try { Invoke-EnviroEasy -Scope Both -Restore 6>$null } catch { $threw = $true }
    Assert-True $threw 'restore without any backup fails with an error'
}
finally {
    $env:APPDATA = $realAppData
    $keyUser.Close(); $keyMachine.Close()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testRoot, $false)
    $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\EnviroEasyTest', $true)
    if ($parent) {
        $empty = ($parent.SubKeyCount -eq 0)
        $parent.Close()
        if ($empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\EnviroEasyTest', $false) }
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    $script:TestKeys = $null
}

Write-Host ''
$color = if ($script:fail) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $color
if ($script:fail) { exit 1 }
exit 0
