#Requires -Version 5.1
<#
.SYNOPSIS
    Enviro Easy - finds the developer tools installed on this PC and fixes your
    PATH and *_HOME environment variables for you - in BOTH the System and the
    User variables - and makes npm work in Windows PowerShell.

.DESCRIPTION
    Detects Node.js (npm), Python (pip), Git, Java JDK, Android SDK, Flutter,
    Dart, Maven and Gradle - including installs in non-default folders - and adds
    whatever is missing to PATH. It never removes anything, never adds
    duplicates, keeps %VARIABLE% entries exactly as they were, and saves a backup
    first so every change can be undone with -Restore.

    Where it looks (-Search):
      Common  (default) PATH, environment variables, the registry, the Python
              "py" launcher and well-known install folders on every drive. Fast.
      C       Everything above PLUS a deep search of the whole C: drive.
      All     Everything above PLUS a deep search of every fixed drive.

    npm in Windows PowerShell:
      Windows blocks npm (npm.ps1) in Windows PowerShell while the execution
      policy is Restricted - a very common "running scripts is disabled" error.
      When Node.js is found, Enviro Easy sets the policy to RemoteSigned (the
      safe, recommended value) and verifies npm in a real Windows PowerShell.
      Use -SkipPolicy to leave the policy alone.

    Run it with no options for a simple menu.

.PARAMETER Scope
    Both (default)   System AND User variables. Asks for administrator permission.
    User             Only your account. No administrator needed.
    Machine          Only the System variables (all users). Needs administrator.

.PARAMETER Tool
    Limit the run to some tools. Default: All.
    Node, Python, Git, Java, Android, Flutter, Dart, Maven, Gradle
    (comma separated; npm = Node, pip = Python, jdk = Java also work)

.PARAMETER Search
    Common (default), C (deep search of C:), All (deep search of all fixed drives).

.PARAMETER Pick
    Ask which tools you have installed instead of looking for all of them.

.PARAMETER DryRun
    Show what would change without changing anything.

.PARAMETER AllVersions
    Add every version found instead of only the newest one.

.PARAMETER Force
    Overwrite JAVA_HOME / ANDROID_HOME even when they already point somewhere valid.

.PARAMETER SkipPolicy
    Do not touch the PowerShell execution policy.

.PARAMETER Yes
    Never ask questions; accept the defaults.

.PARAMETER Restore
    Undo the last run: put PATH, the variables and the execution policy back.

.PARAMETER BackupFile
    With -Restore: use this specific backup file instead of the newest ones.

.EXAMPLE
    .\EnviroEasy.ps1
    Interactive menu.

.EXAMPLE
    .\EnviroEasy.ps1 -DryRun -Search C
    Preview, including a deep search of the C: drive.

.EXAMPLE
    .\EnviroEasy.ps1 -Tool Java,Android -Scope User
    Only fix Java and the Android SDK for your own account.

.EXAMPLE
    .\EnviroEasy.ps1 -Restore
    Undo the last change.
#>
[CmdletBinding()]
param(
    [ValidateSet('Both', 'User', 'Machine')]
    [string]$Scope = 'Both',

    # Not ValidateSet'd on purpose: "-File x.ps1 -Tool Java,Android" arrives as ONE string.
    [string[]]$Tool = @('All'),

    [ValidateSet('Common', 'C', 'All')]
    [string]$Search = 'Common',

    [switch]$Pick,
    [switch]$DryRun,
    [switch]$AllVersions,
    [switch]$Force,
    [switch]$SkipPolicy,
    [switch]$Yes,
    [switch]$Restore,
    [string]$BackupFile,
    [switch]$Elevated   # internal: set on the re-launched administrator window
)

Set-StrictMode -Version 2.0

$script:Version   = '1.1.0'
$script:SelfPath  = $PSCommandPath
$script:TestKeys  = $null   # tests only: @{ User = <key>; Machine = <key> } instead of the real environment keys
$script:BackupDir = $null   # tests only: overrides the backup folder
$script:LastExit  = 0

#region ---------- small helpers ----------

function Join-P {
    # String-only path join (Join-Path throws on drives that do not exist).
    param([string]$Base, [string]$Child)
    if ([string]::IsNullOrEmpty($Child)) { return $Base }
    return [System.IO.Path]::Combine($Base, $Child)
}

function ConvertTo-NormalPath {
    # Expands %VARS%, strips quotes and trailing slashes so entries can be compared.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }
    return $p
}

function Get-VersionKey {
    # Pulls a sortable version out of a folder name: Python312 -> 3.12, jdk-21.0.2 -> 21.0.2
    param([string]$Text)
    if ($Text -match '(?i)python(\d)(\d{1,2})(?!\d)') {
        return [version]('{0}.{1}' -f $Matches[1], $Matches[2])
    }
    if ($Text -match '\d+(\.\d+){0,3}') {
        $v = $Matches[0]
        if ($v -notmatch '\.') { $v = $v + '.0' }
        try { return [version]$v } catch { }
    }
    return [version]'0.0'
}

function Split-PathList {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    return @($Raw -split ';' | Where-Object { $_.Trim() })
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Interactive {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

function Resolve-Scopes {
    # Machine first: it comes first on the real PATH, too.
    param([string]$Scope)
    switch ($Scope) {
        'Both'    { return @('Machine', 'User') }
        'Machine' { return @('Machine') }
        default   { return @('User') }
    }
}

function Get-ScopeLabel {
    param([string]$Scope)
    if ($Scope -eq 'Machine') { return 'System' }
    return 'User'
}

function Write-Tag {
    param([string]$Tag, [ConsoleColor]$Color, [string]$Name, [string]$Detail)
    Write-Host ('  [{0}] ' -f $Tag) -ForegroundColor $Color -NoNewline
    Write-Host ($Name.PadRight(11)) -NoNewline
    Write-Host $Detail -ForegroundColor Gray
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Valid, [string]$Default = '')
    while ($true) {
        $answer = ([string](Read-Host $Prompt)).Trim()
        if (-not $answer -and $Default) { return $Default }
        foreach ($v in $Valid) { if ($answer -ieq $v) { return $v } }
        Write-Host ('  Please type one of: ' + ($Valid -join ', ')) -ForegroundColor Yellow
    }
}

#endregion

#region ---------- environment storage (registry) ----------

function Open-EnvKey {
    param([string]$Scope, [bool]$Writable = $false)
    if ($script:TestKeys) { return $script:TestKeys[$Scope] }
    if ($Scope -eq 'Machine') {
        return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $Writable)
    }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $Writable)
}

function Get-EnvRaw {
    # Reads the value WITHOUT expanding %VARS%, plus its registry type.
    param([string]$Scope, [string]$Name)
    $key = Open-EnvKey -Scope $Scope
    try {
        $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $null
        if ($null -ne $value) { $kind = $key.GetValueKind($Name) }
        return [pscustomobject]@{ Value = $value; Kind = $kind }
    }
    finally { if (-not $script:TestKeys) { $key.Dispose() } }
}

function Set-EnvRaw {
    param([string]$Scope, [string]$Name, [string]$Value, $Kind)
    if (-not $Kind) { $Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $key = Open-EnvKey -Scope $Scope -Writable $true
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { if (-not $script:TestKeys) { $key.Dispose() } }
}

function Remove-EnvRaw {
    param([string]$Scope, [string]$Name)
    $key = Open-EnvKey -Scope $Scope -Writable $true
    try { $key.DeleteValue($Name, $false) }
    finally { if (-not $script:TestKeys) { $key.Dispose() } }
}

function Get-EnvScopeValue {
    # Expanded value of a variable in ONE scope, or $null.
    param([string]$Scope, [string]$Name)
    $raw = (Get-EnvRaw -Scope $Scope -Name $Name).Value
    if ($raw) { return [Environment]::ExpandEnvironmentVariables([string]$raw) }
    return $null
}

function Get-EnvValue {
    # Effective value of a variable (User beats System, then this process).
    param([string]$Name)
    foreach ($s in @('User', 'Machine')) {
        $v = Get-EnvScopeValue -Scope $s -Name $Name
        if ($v) { return $v }
    }
    if (-not $script:TestKeys) {
        $p = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if ($p) { return $p }
    }
    return $null
}

function Get-EffectivePath {
    # Every folder that is on PATH for new processes (System first, then User), normalized.
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($s in @('Machine', 'User')) {
        $raw = (Get-EnvRaw -Scope $s -Name 'Path').Value
        foreach ($e in @(Split-PathList $raw)) {
            $n = ConvertTo-NormalPath $e
            if ($n) { $result.Add($n) }
        }
    }
    return $result.ToArray()
}

function Send-EnvironmentChange {
    # Tells Explorer and other running programs that the environment changed.
    if ($script:TestKeys) { return }
    try {
        if (-not ('EnviroEasy.Native' -as [type])) {
            Add-Type -Namespace EnviroEasy -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [void][EnviroEasy.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    }
    catch { }
}

function Update-ProcessEnvironment {
    # Makes this session see the new PATH so the verification step is truthful.
    param([string[]]$VarNames)
    if ($script:TestKeys) { return }
    $parts = @()
    foreach ($s in @('Machine', 'User')) {
        $raw = (Get-EnvRaw -Scope $s -Name 'Path').Value
        if ($raw) { $parts += [Environment]::ExpandEnvironmentVariables([string]$raw) }
    }
    $env:Path = ($parts -join ';')
    foreach ($n in $VarNames) {
        $v = Get-EnvValue -Name $n
        if ($v) { Set-Item -LiteralPath "Env:$n" -Value $v }
    }
}

#endregion

#region ---------- PowerShell execution policy (npm.ps1) ----------

# Wrapped in tiny functions so the tests can replace them and never touch the real policy.
function Get-PolicyList { return @(Get-ExecutionPolicy -List) }

function Set-PolicyValue {
    param([string]$PolicyScope, [string]$Policy)
    try { Set-ExecutionPolicy -ExecutionPolicy $Policy -Scope $PolicyScope -Force -ErrorAction Stop }
    catch { $script:LastPolicyError = $_.Exception.Message }   # PowerShell may complain that Process scope overrides; we re-read to check
}

function Get-PolicyState {
    # Effective policy for NEW Windows PowerShell windows. The Process scope is ignored: it only
    # exists because the launcher used -ExecutionPolicy Bypass.
    param([hashtable]$ByScope)
    $effective = 'Restricted'; $source = 'Default'
    foreach ($s in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $v = $ByScope[$s]
        if ($v -and $v -ne 'Undefined') { $effective = $v; $source = $s; break }
    }
    [pscustomobject]@{
        Effective = $effective
        Source    = $source
        Blocking  = ($effective -in @('Restricted', 'AllSigned'))
        Gpo       = ($source -in @('MachinePolicy', 'UserPolicy'))
    }
}

function Get-PolicyPlan {
    <# Decides what (if anything) to change so npm.ps1 can run. Pure given the policy list. #>
    param([string[]]$Scopes, [object[]]$List)
    $by = @{}
    foreach ($e in $List) { $by[[string]$e.Scope] = [string]$e.ExecutionPolicy }
    $state = Get-PolicyState -ByScope $by
    $targets = New-Object System.Collections.Generic.List[object]
    if ($state.Blocking -and -not $state.Gpo) {
        $want = New-Object System.Collections.Generic.List[string]
        if ($Scopes -contains 'User') { $want.Add('CurrentUser') }
        if ($Scopes -contains 'Machine') { $want.Add('LocalMachine') }
        if ($state.Source -eq 'CurrentUser' -and -not $want.Contains('CurrentUser')) { $want.Add('CurrentUser') }
        foreach ($ps in $want) {
            $prev = $by[$ps]
            if (-not $prev) { $prev = 'Undefined' }
            if ($prev -in @('Restricted', 'AllSigned', 'Undefined')) {
                $targets.Add([pscustomobject]@{ PolicyScope = $ps; Previous = $prev; Scope = $(if ($ps -eq 'LocalMachine') { 'Machine' } else { 'User' }) })
            }
        }
    }
    $after = @{}; foreach ($k in $by.Keys) { $after[$k] = $by[$k] }
    foreach ($t in $targets) { $after[$t.PolicyScope] = 'RemoteSigned' }
    $stateAfter = Get-PolicyState -ByScope $after
    [pscustomobject]@{ State = $state; Targets = $targets.ToArray(); StillBlockedAfter = $stateAfter.Blocking }
}

function Update-PolicyTargets {
    param([object[]]$Targets)
    foreach ($t in $Targets) {
        Set-PolicyValue -PolicyScope $t.PolicyScope -Policy 'RemoteSigned'
        $now = @(Get-PolicyList | Where-Object { [string]$_.Scope -eq $t.PolicyScope }) | Select-Object -First 1
        if ($now -and [string]$now.ExecutionPolicy -eq 'RemoteSigned') {
            Write-Host ("  Execution policy ({0}) set to RemoteSigned." -f $t.PolicyScope) -ForegroundColor Green
        }
        else {
            Write-Host ("  Could not set the {0} execution policy: {1}" -f $t.PolicyScope, $script:LastPolicyError) -ForegroundColor Yellow
        }
    }
}

#endregion

#region ---------- backups ----------

function Get-BackupDir {
    if ($script:BackupDir) { return $script:BackupDir }
    return (Join-P $env:LOCALAPPDATA 'EnviroEasy\backups')
}

function Save-Backup {
    param([string]$Scope, [string[]]$VarNames, [string]$Prefix = 'backup', [string]$PolicyScope, [string]$PolicyPrevious)
    $dir = Get-BackupDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $pathRaw = Get-EnvRaw -Scope $Scope -Name 'Path'
    $vars = [ordered]@{}
    foreach ($n in $VarNames) {
        $r = Get-EnvRaw -Scope $Scope -Name $n
        $vars[$n] = [ordered]@{ Value = $r.Value; Kind = [string]$r.Kind }
    }
    $policy = $null
    if ($PolicyScope) { $policy = [ordered]@{ Scope = $PolicyScope; Previous = $PolicyPrevious } }
    $doc = [ordered]@{
        Tool            = 'EnviroEasy'
        Version         = $script:Version
        Scope           = $Scope
        Created         = (Get-Date).ToString('s')
        Path            = [ordered]@{ Value = $pathRaw.Value; Kind = [string]$pathRaw.Kind }
        Variables       = $vars
        ExecutionPolicy = $policy
    }
    $file = Join-P $dir ('{0}-{1}-{2}.json' -f $Prefix, $Scope, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Read-BackupDoc {
    param([string]$File)
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { throw "Backup file not found: $File" }
    $doc = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
    if ($doc.Tool -ne 'EnviroEasy') { throw "'$File' is not an Enviro Easy backup." }
    return $doc
}

function Restore-EnvBackup {
    param([string]$Scope, [string]$BackupFile, [bool]$DryRun)
    $file = $BackupFile
    if (-not $file) {
        $dir = Get-BackupDir
        if (Test-Path -LiteralPath $dir) {
            $latest = @(Get-ChildItem -LiteralPath $dir -Filter "backup-$Scope-*.json" | Sort-Object Name -Descending) | Select-Object -First 1
            if ($latest) { $file = $latest.FullName }
        }
    }
    if (-not $file) { throw "No $(Get-ScopeLabel $Scope) backup found in $(Get-BackupDir). Nothing to restore." }

    $doc = Read-BackupDoc -File $file
    if ($doc.Scope -ne $Scope) { throw "That backup is for the $($doc.Scope) scope." }

    $label = Get-ScopeLabel $Scope
    Write-Host "  [$label] backup : $file" -ForegroundColor Gray
    Write-Host "  [$label] taken  : $($doc.Created)" -ForegroundColor Gray
    $varNames = @($doc.Variables.PSObject.Properties | ForEach-Object { $_.Name })
    $policy = $null
    if ($doc.PSObject.Properties['ExecutionPolicy'] -and $doc.ExecutionPolicy) { $policy = $doc.ExecutionPolicy }

    if ($DryRun) {
        Write-Host "  [$label] dry run - would restore PATH, $($varNames.Count) variable(s)$(if ($policy) { ' and the execution policy' }). Nothing was changed." -ForegroundColor Yellow
        return
    }

    $safety = Save-Backup -Scope $Scope -VarNames $varNames -Prefix 'before-restore'
    if ($null -ne $doc.Path.Value) {
        Set-EnvRaw -Scope $Scope -Name 'Path' -Value ([string]$doc.Path.Value) -Kind $doc.Path.Kind
    }
    foreach ($n in $varNames) {
        $entry = $doc.Variables.$n
        if ($null -eq $entry.Value) {
            Remove-EnvRaw -Scope $Scope -Name $n
            Write-Host "  [$label] removed variable $n (it did not exist before)" -ForegroundColor Green
        }
        else {
            Set-EnvRaw -Scope $Scope -Name $n -Value ([string]$entry.Value) -Kind $entry.Kind
            Write-Host "  [$label] restored variable $n" -ForegroundColor Green
        }
    }
    if ($policy) {
        Set-PolicyValue -PolicyScope ([string]$policy.Scope) -Policy ([string]$policy.Previous)
        Write-Host ("  [{0}] execution policy ({1}) put back to {2}" -f $label, $policy.Scope, $policy.Previous) -ForegroundColor Green
    }
    Send-EnvironmentChange
    Write-Host "  [$label] restored PATH." -ForegroundColor Green
    Write-Host "  (state before this restore saved to $safety)" -ForegroundColor DarkGray
}

#endregion

#region ---------- tool catalogue ----------

function New-ToolSpec {
    param(
        [string]$Key, [string]$Name, [string]$Label = '', [string]$Marker, [string[]]$Bins,
        [string[]]$Extras = @(), [string[]]$CreateDirs = @(), [string[]]$EnvVars = @(), [string]$SetVar = '',
        [string[]]$Registry = @(), [string[]]$Patterns = @(), [string[]]$Verify = @(),
        [scriptblock]$ExtraRoots = $null, [string]$MissingNote = ''
    )
    if (-not $Label) { $Label = $Name }
    [pscustomobject]@{
        Key = $Key; Name = $Name; Label = $Label; Marker = $Marker; Bins = $Bins; Extras = $Extras
        CreateDirs = $CreateDirs; EnvVars = $EnvVars; SetVar = $SetVar; Registry = $Registry
        Patterns = $Patterns; Verify = $Verify; ExtraRoots = $ExtraRoots; MissingNote = $MissingNote
    }
}

# Notes on the fields:
#   Marker      file (relative to the install root) that proves the tool is really there
#   Bins        folders (relative to the root) that belong on PATH; 'a|b' = first one that exists
#   Extras      per-user folders (absolute, may contain * and %VARS%) added to the USER path when they exist
#   CreateDirs  per-user folders that are created when missing (npm needs %APPDATA%\npm to exist)
#   Registry    'Key\Under\SOFTWARE|ValueName' install records (HKLM, HKLM\WOW6432Node, HKCU)
#   Patterns    well-known install folders; {DRIVES} expands to every fixed drive (C:\, D:\, ...)
#   Verify      'command|arguments' run at the end; an empty argument only checks it resolves

$script:PyLauncherRoots = {
    $py = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { return }
    try { $out = @(& $py.Source -0p 2>$null) } catch { return }
    foreach ($line in $out) {
        if ("$line" -match '([A-Za-z]:\\.*?\.exe)') { Split-Path $Matches[1] -Parent }
    }
}

$script:Tools = @(
    (New-ToolSpec -Key 'Node' -Name 'Node.js' -Label 'Node.js and npm' -Marker 'node.exe' -Bins @('') `
        -Extras @('%APPDATA%\npm') -CreateDirs @('%APPDATA%\npm') -EnvVars @('NVM_SYMLINK') `
        -Registry @('Node.js|InstallPath') `
        -Patterns @('%ProgramFiles%\nodejs', '%ProgramFiles(x86)%\nodejs', '%LOCALAPPDATA%\Programs\nodejs', '{DRIVES}nodejs', '{DRIVES}Program Files\nodejs') `
        -Verify @('node|--version', 'npm|--version', 'npx|--version')),

    (New-ToolSpec -Key 'Python' -Name 'Python' -Label 'Python and pip' -Marker 'python.exe' -Bins @('', 'Scripts') `
        -Extras @('%APPDATA%\Python\Python*\Scripts') -EnvVars @('PYTHONHOME') `
        -Registry @('Python\PythonCore\*\InstallPath|(default)') `
        -Patterns @('%LOCALAPPDATA%\Programs\Python\Python*', '%ProgramFiles%\Python*', '%ProgramFiles(x86)%\Python*', '{DRIVES}Python*') `
        -ExtraRoots $script:PyLauncherRoots `
        -Verify @('python|--version', 'pip|--version')),

    (New-ToolSpec -Key 'Git' -Name 'Git' -Marker 'cmd\git.exe' -Bins @('cmd') `
        -EnvVars @('GIT_INSTALL_ROOT') -Registry @('GitForWindows|InstallPath') `
        -Patterns @('%ProgramFiles%\Git', '%ProgramFiles(x86)%\Git', '%LOCALAPPDATA%\Programs\Git', '{DRIVES}Git', '{DRIVES}Program Files\Git') `
        -Verify @('git|--version')),

    (New-ToolSpec -Key 'Java' -Name 'Java JDK' -Marker 'bin\javac.exe' -Bins @('bin') `
        -EnvVars @('JAVA_HOME') -SetVar 'JAVA_HOME' `
        -Registry @('JavaSoft\JDK\*|JavaHome', 'JavaSoft\Java Development Kit\*|JavaHome', 'Eclipse Adoptium\JDK\*\hotspot\MSI|Path', 'Microsoft\JDK\*\hotspot\MSI|Path') `
        -Patterns @('%ProgramFiles%\Java\jdk*', '%ProgramFiles%\Eclipse Adoptium\jdk*', '%ProgramFiles%\Microsoft\jdk*', '%ProgramFiles%\Zulu\zulu*', '%ProgramFiles%\Amazon Corretto\jdk*', '%ProgramFiles%\BellSoft\LibericaJDK*', '%ProgramFiles%\Semeru\jdk*', '%LOCALAPPDATA%\Programs\Eclipse Adoptium\jdk*', '%USERPROFILE%\.jdks\*', '{DRIVES}Java\jdk*', '{DRIVES}Program Files\Java\jdk*', '%ProgramFiles%\Android\Android Studio\jbr', '%LOCALAPPDATA%\Programs\Android Studio\jbr') `
        -Verify @('java|-version', 'javac|-version')),

    (New-ToolSpec -Key 'Android' -Name 'Android' -Label 'Android SDK' -Marker 'platform-tools\adb.exe' `
        -Bins @('platform-tools', 'cmdline-tools\latest\bin|cmdline-tools\*\bin', 'emulator') `
        -EnvVars @('ANDROID_HOME', 'ANDROID_SDK_ROOT') -SetVar 'ANDROID_HOME' `
        -Registry @('Android SDK Tools|Path') `
        -Patterns @('%LOCALAPPDATA%\Android\Sdk', '%ProgramFiles(x86)%\Android\android-sdk', '%ProgramFiles%\Android\android-sdk', '{DRIVES}Android\Sdk', '{DRIVES}Android\android-sdk') `
        -Verify @('adb|--version', 'sdkmanager|')),

    (New-ToolSpec -Key 'Flutter' -Name 'Flutter' -Marker 'bin\flutter.bat' -Bins @('bin') `
        -EnvVars @('FLUTTER_ROOT') `
        -Patterns @('%USERPROFILE%\flutter', '%USERPROFILE%\dev\flutter', '%USERPROFILE%\development\flutter', '%USERPROFILE%\src\flutter', '%USERPROFILE%\*\flutter', '%LOCALAPPDATA%\flutter', '%ProgramFiles%\flutter', '{DRIVES}flutter', '{DRIVES}src\flutter', '{DRIVES}dev\flutter', '{DRIVES}tools\flutter', '{DRIVES}development\flutter') `
        -Verify @('flutter|')),

    (New-ToolSpec -Key 'Dart' -Name 'Dart' -Marker 'bin\dart.exe' -Bins @('bin') `
        -EnvVars @('DART_SDK') `
        -Patterns @('{DRIVES}tools\dart-sdk', '{DRIVES}dart-sdk', '%ProgramFiles%\Dart\dart-sdk', '%LOCALAPPDATA%\Programs\dart-sdk', '%USERPROFILE%\dart-sdk') `
        -Verify @('dart|--version') -MissingNote 'not needed if Flutter is installed - it bundles Dart'),

    (New-ToolSpec -Key 'Maven' -Name 'Maven' -Marker 'bin\mvn.cmd' -Bins @('bin') `
        -EnvVars @('MAVEN_HOME', 'M2_HOME') `
        -Patterns @('%ProgramFiles%\Apache\apache-maven-*', '%ProgramFiles%\apache-maven-*', '{DRIVES}apache-maven-*', '{DRIVES}Apache\apache-maven-*', '{DRIVES}tools\apache-maven-*', '{DRIVES}maven\apache-maven-*', '%USERPROFILE%\apache-maven-*') `
        -Verify @('mvn|-v')),

    (New-ToolSpec -Key 'Gradle' -Name 'Gradle' -Marker 'bin\gradle.bat' -Bins @('bin') `
        -EnvVars @('GRADLE_HOME') `
        -Patterns @('%ProgramFiles%\Gradle\gradle-*', '{DRIVES}Gradle\gradle-*', '{DRIVES}gradle-*', '{DRIVES}tools\gradle-*', '%USERPROFILE%\gradle-*') `
        -Verify @('gradle|--version'))
)

$script:ToolAliases = @{ npm = 'Node'; nodejs = 'Node'; pip = 'Python'; jdk = 'Java'; sdk = 'Android'; adb = 'Android'; mvn = 'Maven' }

function Resolve-ToolSelection {
    # Accepts 'All', 'Java,Android', @('Java','Android'), aliases (npm, pip, jdk) - in any case.
    param([string[]]$Names)
    $keys = @($Names | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
    if ($keys.Count -eq 0 -or @($keys | Where-Object { $_ -ieq 'All' }).Count -gt 0) { return @($script:Tools) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        $lookup = $k
        if ($script:ToolAliases.ContainsKey($k.ToLowerInvariant())) { $lookup = $script:ToolAliases[$k.ToLowerInvariant()] }
        $m = @($script:Tools | Where-Object { $_.Key -ieq $lookup }) | Select-Object -First 1
        if (-not $m) { throw ("Unknown tool '{0}'. Valid tools: All, {1}" -f $k, (($script:Tools | ForEach-Object { $_.Key }) -join ', ')) }
        if (-not $out.Contains($m)) { $out.Add($m) }
    }
    return $out.ToArray()
}

#endregion

#region ---------- detection (quick) ----------

function Get-FixedDrives {
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.Name })
}

function Expand-Pattern {
    # Expands %VARS%, {DRIVES} and * wildcards into folders that exist.
    param([string]$Pattern)
    $candidates = @($Pattern)
    if ($Pattern.StartsWith('{DRIVES}')) {
        $rest = $Pattern.Substring(8)
        $candidates = @(Get-FixedDrives | ForEach-Object { Join-P $_ $rest })
    }
    foreach ($c in $candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($c)
        if ($expanded -match '%') { continue }   # a variable that is not defined on this PC
        Get-Item -Path $expanded -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            ForEach-Object { $_.FullName }
    }
}

function Get-RegistryPaths {
    param([string[]]$Specs)
    foreach ($spec in $Specs) {
        $parts = $spec -split '\|', 2
        foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\SOFTWARE')) {
            $items = @(Get-ItemProperty -Path ($base + '\' + $parts[0]) -ErrorAction SilentlyContinue)
            foreach ($item in $items) {
                if ($null -eq $item) { continue }
                $prop = $item.PSObject.Properties[$parts[1]]
                if ($prop -and $prop.Value) { ConvertTo-NormalPath ([string]$prop.Value) }
            }
        }
    }
}

function Find-ToolRoots {
    <#
      Returns the install root(s) to use for a tool, every candidate found (best first), and
      where they came from. -Deep carries results of the deep drive search, if one was run.
    #>
    param($Tool, [string[]]$Effective, [bool]$AllVersions, [object[]]$Deep = @())

    $markerLeaf = Split-Path $Tool.Marker -Leaf
    $markerDir  = Split-Path $Tool.Marker -Parent

    # 1) already on PATH?
    foreach ($dir in $Effective) {
        if ($dir -match 'WindowsApps') { continue }
        if (-not (Test-Path -LiteralPath (Join-P $dir $markerLeaf) -PathType Leaf)) { continue }
        $root = $null
        if (-not $markerDir) { $root = $dir }
        elseif ($dir.EndsWith('\' + $markerDir, [StringComparison]::OrdinalIgnoreCase)) { $root = Split-Path $dir -Parent }
        if ($root -and (Test-Path -LiteralPath (Join-P $root $Tool.Marker) -PathType Leaf)) {
            return [pscustomobject]@{ Roots = @($root); Candidates = @($root); Source = 'PATH' }
        }
    }

    # 2) search: env vars first, then registry, known folders, extras, deep search results
    $cands = New-Object System.Collections.Generic.List[object]
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($path, $rank)
        if (-not $path) { return }
        $n = ConvertTo-NormalPath $path
        if (-not $n -or $n -match 'WindowsApps') { return }
        if (-not (Test-Path -LiteralPath (Join-P $n $Tool.Marker) -PathType Leaf)) { return }
        if (-not $seen.Add($n)) { return }
        $cands.Add([pscustomobject]@{ Path = $n; Rank = $rank; Ver = (Get-VersionKey (Split-Path $n -Leaf)) })
    }
    foreach ($ev in $Tool.EnvVars) { & $add (Get-EnvValue -Name $ev) 0 }
    foreach ($p in @(Get-RegistryPaths -Specs $Tool.Registry)) { & $add $p 1 }
    foreach ($pat in $Tool.Patterns) { foreach ($p in @(Expand-Pattern -Pattern $pat)) { & $add $p 1 } }
    if ($Tool.ExtraRoots) { foreach ($p in @(& $Tool.ExtraRoots)) { & $add $p 1 } }
    foreach ($d in $Deep) { & $add $d.Path $d.Rank }

    if ($cands.Count -eq 0) { return [pscustomobject]@{ Roots = @(); Candidates = @(); Source = '' } }

    $sorted = @($cands | Sort-Object -Property @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Ver'; Descending = $true }, 'Path')
    $all = @($sorted | ForEach-Object { $_.Path })
    $roots = $all
    if (-not $AllVersions) { $roots = @($all[0]) }
    return [pscustomobject]@{ Roots = $roots; Candidates = $all; Source = 'search' }
}

function Resolve-ToolDirs {
    # Which folders under a root belong on PATH (only ones that exist).
    param($Tool, [string]$Root)
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($bin in $Tool.Bins) {
        foreach ($alt in ($bin -split '\|')) {
            $hit = $null
            if ($alt -match '^(.*)\\\*\\(.*)$') {
                $parent = Join-P $Root $Matches[1]
                $tail = $Matches[2]
                if (Test-Path -LiteralPath $parent) {
                    $hit = Get-ChildItem -LiteralPath $parent -Directory |
                        Sort-Object { Get-VersionKey $_.Name } -Descending |
                        ForEach-Object { Join-P $_.FullName $tail } |
                        Where-Object { Test-Path -LiteralPath $_ } |
                        Select-Object -First 1
                }
            }
            else {
                $full = Join-P $Root $alt
                if (Test-Path -LiteralPath $full) { $hit = $full }
            }
            if ($hit) { $dirs.Add((ConvertTo-NormalPath $hit)); break }
        }
    }
    return $dirs.ToArray()
}

function Get-ToolUserDirs {
    # Per-user folders for a tool: existing Extras, plus CreateDirs (existing or to be created).
    param($Tool)
    $existing = New-Object System.Collections.Generic.List[string]
    $toCreate = New-Object System.Collections.Generic.List[string]
    foreach ($extra in $Tool.Extras) {
        foreach ($d in @(Expand-Pattern -Pattern $extra)) { $existing.Add((ConvertTo-NormalPath $d)) }
    }
    foreach ($c in $Tool.CreateDirs) {
        $full = ConvertTo-NormalPath $c
        if (-not $full -or $full -match '%') { continue }
        if (-not (Test-Path -LiteralPath $full)) { $toCreate.Add($full) }
    }
    return [pscustomobject]@{ Existing = @($existing | Select-Object -Unique); ToCreate = $toCreate.ToArray() }
}

#endregion

#region ---------- deep drive search ----------

# Folders never worth entering (caches, system areas, other apps' bundled copies).
$script:DeepSkipNames = @('node_modules', '.git', '.svn', '.hg', '__pycache__', 'site-packages', '.gradle', '.m2', '.nuget', '.npm', '.cache',
    'Temp', 'WinSxS', 'WindowsApps', 'Microsoft Visual Studio', '$Recycle.Bin', 'System Volume Information')
$script:DeepSkipRoot  = @('Windows', 'Recovery', '$WinREAgent', 'Windows.old', 'PerfLogs', 'Config.Msi', 'Documents and Settings')
# Found, but probably some other program's private copy: only used if nothing better exists.
$script:DeepLowPriority = '(?i)\\(jbr|jre)(\\|$)|JetBrains|Android Studio|\\plugins\\|\\Electron|\\resources\\app|Microsoft VS Code|\\Steam\\|Epic Games'
# Found, but never wanted.
$script:DeepIgnore = '(?i)\\flutter\\bin\\cache\\'

function Initialize-DeepScanner {
    if ('EnviroEasy.DeepScanner' -as [type]) { return }
    Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace EnviroEasy
{
    public class DeepScanner
    {
        private readonly string[] roots;
        private readonly HashSet<string> fileNames;
        private readonly HashSet<string> skipNames;
        private readonly HashSet<string> skipRootNames;
        private readonly List<string> hits = new List<string>();
        public volatile int Dirs;
        public volatile bool Done;
        public volatile bool Cancel;
        public volatile string Current = "";

        public DeepScanner(string[] roots, string[] fileNames, string[] skipNames, string[] skipRootNames)
        {
            this.roots = roots;
            this.fileNames = new HashSet<string>(fileNames, StringComparer.OrdinalIgnoreCase);
            this.skipNames = new HashSet<string>(skipNames, StringComparer.OrdinalIgnoreCase);
            this.skipRootNames = new HashSet<string>(skipRootNames, StringComparer.OrdinalIgnoreCase);
        }

        public void Start()
        {
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        public string[] GetHits()
        {
            lock (hits) { return hits.ToArray(); }
        }

        private void Run()
        {
            try
            {
                foreach (string root in roots)
                {
                    Stack<KeyValuePair<string, int>> stack = new Stack<KeyValuePair<string, int>>();
                    stack.Push(new KeyValuePair<string, int>(root, 0));
                    while (stack.Count > 0 && !Cancel)
                    {
                        KeyValuePair<string, int> item = stack.Pop();
                        string dir = item.Key;
                        Dirs++;
                        Current = dir;
                        try
                        {
                            foreach (string f in Directory.EnumerateFiles(dir))
                            {
                                if (fileNames.Contains(Path.GetFileName(f)))
                                {
                                    lock (hits) { hits.Add(f); }
                                }
                            }
                        }
                        catch (Exception) { }
                        try
                        {
                            DirectoryInfo di = new DirectoryInfo(dir);
                            foreach (DirectoryInfo sub in di.EnumerateDirectories())
                            {
                                if ((sub.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                                if (skipNames.Contains(sub.Name)) continue;
                                if (item.Value == 0 && skipRootNames.Contains(sub.Name)) continue;
                                stack.Push(new KeyValuePair<string, int>(sub.FullName, item.Value + 1));
                            }
                        }
                        catch (Exception) { }
                    }
                }
            }
            finally { Done = true; }
        }
    }
}
'@
}

function ConvertTo-ToolHits {
    <# Turns raw file hits into { ToolKey -> [ {Path; Rank} ] }. Pure given the file system. #>
    param([string[]]$Hits, [object[]]$Tools)
    $found = @{}
    foreach ($t in $Tools) {
        $leaf = Split-Path $t.Marker -Leaf
        $rel  = Split-Path $t.Marker -Parent
        $list = New-Object System.Collections.Generic.List[object]
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($h in $Hits) {
            if ((Split-Path $h -Leaf) -ine $leaf) { continue }
            if ($h -match $script:DeepIgnore -or $h -match 'WindowsApps') { continue }
            $hitDir = Split-Path $h -Parent
            $root = $hitDir
            if ($rel) {
                if (-not $hitDir.EndsWith('\' + $rel, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $root = $hitDir.Substring(0, $hitDir.Length - $rel.Length).TrimEnd('\')
            }
            if (-not $root -or -not (Test-Path -LiteralPath (Join-P $root $t.Marker) -PathType Leaf)) { continue }
            if ($t.Key -eq 'Python') {   # skip virtual environments
                if ((Test-Path -LiteralPath (Join-P $root 'pyvenv.cfg')) -or (Test-Path -LiteralPath (Join-P (Split-Path $root -Parent) 'pyvenv.cfg'))) { continue }
            }
            if (-not $seen.Add($root)) { continue }
            $rank = 2
            if ($root -match $script:DeepLowPriority) { $rank = 3 }
            $list.Add([pscustomobject]@{ Path = $root; Rank = $rank })
        }
        $found[$t.Key] = $list.ToArray()
    }
    return $found
}

function Invoke-DeepScan {
    <# Walks the given folders for the tools' marker files. Shows progress. #>
    param([string[]]$Roots, [object[]]$Tools, [bool]$Quiet = $false)
    Initialize-DeepScanner
    $names = @($Tools | ForEach-Object { Split-Path $_.Marker -Leaf } | Select-Object -Unique)
    $scanner = [EnviroEasy.DeepScanner]::new([string[]]$Roots, [string[]]$names, [string[]]$script:DeepSkipNames, [string[]]$script:DeepSkipRoot)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $scanner.Start()
    try {
        while (-not $scanner.Done) {
            Start-Sleep -Milliseconds 300
            if (-not $Quiet) {
                $cur = [string]$scanner.Current
                $width = 70
                try { $width = [Math]::Max(30, [Console]::WindowWidth - 30) } catch { }
                if ($cur.Length -gt $width) { $cur = '...' + $cur.Substring($cur.Length - $width + 3) }
                Write-Host ("`r  Searching... {0,9:N0} folders  {1}s  {2}" -f $scanner.Dirs, [int]$watch.Elapsed.TotalSeconds, $cur).PadRight(100).Substring(0, 100) -NoNewline -ForegroundColor DarkGray
            }
        }
    }
    finally { $scanner.Cancel = $true }
    if (-not $Quiet) { Write-Host ("`r" + (' ' * 100) + "`r") -NoNewline }
    $hits = $scanner.GetHits()
    if (-not $Quiet) { Write-Host ("  Searched {0:N0} folders in {1}s." -f $scanner.Dirs, [int]$watch.Elapsed.TotalSeconds) -ForegroundColor DarkGray }
    return (ConvertTo-ToolHits -Hits $hits -Tools $Tools)
}

#endregion

#region ---------- planning ----------

function Add-PathEntries {
    <#
      Pure function. Returns the new PATH list (existing entries untouched, in their
      original text) plus what was added. New folders go in front of the Windows Store
      "WindowsApps" entry when there is one, so a real python.exe beats the Store stub.
    #>
    param([string[]]$Current, [string[]]$Effective, [string[]]$Wanted)

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Current | Where-Object { $_ })) { $list.Add($c) }
    $added = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Effective | Where-Object { $_ })) { [void]$seen.Add((ConvertTo-NormalPath $e)) }

    $insertAt = $list.Count
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i] -match 'Microsoft\\WindowsApps') { $insertAt = $i; break }
    }
    foreach ($w in @($Wanted | Where-Object { $_ })) {
        $n = ConvertTo-NormalPath $w
        if (-not $n -or -not $seen.Add($n)) { continue }
        $list.Insert($insertAt, $n)
        $insertAt++
        $added.Add($n)
    }
    return [pscustomobject]@{ List = $list.ToArray(); Added = $added.ToArray() }
}

function Format-RelaunchArguments {
    # Builds the argument string for re-running this script in an administrator window.
    param([string]$ScriptPath, [string]$Scope, [string[]]$ToolKeys, [string]$Search, [bool]$AllVersions, [bool]$Force, [bool]$SkipPolicy, [bool]$Yes, [bool]$Restore, [string]$BackupFile)
    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)))
    $a.AddRange([string[]]@('-Scope', $Scope, '-Search', $Search))
    if ($ToolKeys.Count -gt 0) { $a.AddRange([string[]]@('-Tool', ($ToolKeys -join ','))) }
    if ($AllVersions) { $a.Add('-AllVersions') }
    if ($Force) { $a.Add('-Force') }
    if ($SkipPolicy) { $a.Add('-SkipPolicy') }
    if ($Yes) { $a.Add('-Yes') }
    if ($Restore) { $a.Add('-Restore') }
    if ($BackupFile) { $a.AddRange([string[]]@('-BackupFile', ('"{0}"' -f $BackupFile))) }
    $a.Add('-Elevated')
    return ($a -join ' ')
}

#endregion

#region ---------- verification ----------

function Invoke-Verify {
    # Command Prompt view: resolve and run each command using the refreshed PATH.
    param($Tool)
    foreach ($entry in $Tool.Verify) {
        $parts = $entry -split '\|', 2
        $name = $parts[0]
        $cmdArgs = ''
        if ($parts.Count -gt 1) { $cmdArgs = $parts[1] }

        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) {
            Write-Tag 'FAIL' Red $name 'not found on PATH - open a NEW terminal, or check the install'
            continue
        }
        if ($cmd.Source -match 'WindowsApps') {
            Write-Tag 'WARN' Yellow $name 'resolves to the Microsoft Store stub - turn off its App execution alias (see README)'
            continue
        }
        if (-not $cmdArgs) { Write-Tag ' OK ' Green $name $cmd.Source; continue }

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = @(& $cmd.Source $cmdArgs 2>&1 | ForEach-Object { "$_" }) }
        catch { $out = @("$_") }
        finally { $ErrorActionPreference = $prev }

        $line = @($out | Where-Object { $_ -match '\d+\.\d+' }) | Select-Object -First 1
        if ($line) { Write-Tag ' OK ' Green $name ($line.Trim()) }
        else {
            $first = @($out | Where-Object { $_ }) | Select-Object -First 1
            Write-Tag 'WARN' Yellow $name ('did not report a version' + $(if ($first) { ': ' + $first } else { '' }))
        }
    }
}

function Invoke-PowerShellCheck {
    <#
      Runs the same commands inside a brand-new Windows PowerShell with the machine's REAL
      execution policy (the launcher's Bypass is not inherited) - exactly what you get when
      you open PowerShell and type "npm".
    #>
    param([object[]]$Tools)
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Tools) { foreach ($e in $t.Verify) { $entries.Add($e) } }
    if ($entries.Count -eq 0) { return }

    $quoted = ($entries | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $script = @"
`$ErrorActionPreference = 'Continue'
foreach (`$e in @($quoted)) {
    `$p = `$e -split '\|', 2
    `$name = `$p[0]; `$a = ''; if (`$p.Count -gt 1) { `$a = `$p[1] }
    try {
        `$c = Get-Command `$name -ErrorAction Stop | Select-Object -First 1
        if (-not `$a) { 'OK|' + `$name + '|' + `$c.Source; continue }
        `$o = @(& `$name `$a 2>&1 | ForEach-Object { "`$_" })
        `$l = @(`$o | Where-Object { `$_ -match '\d+\.\d+' }) | Select-Object -First 1
        if (`$l) { 'OK|' + `$name + '|' + `$l.Trim() } else { 'WARN|' + `$name + '|no version reported' }
    } catch { 'FAIL|' + `$name + '|' + (`$_.Exception.Message -replace '\s+', ' ') }
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $saved = $env:PSExecutionPolicyPreference
    $env:PSExecutionPolicyPreference = $null
    $ps = Join-P $PSHOME 'powershell.exe'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $ps -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" }) }
    finally { $env:PSExecutionPolicyPreference = $saved; $ErrorActionPreference = $prev }

    foreach ($l in $lines) {
        $p = $l -split '\|', 3
        if ($p.Count -lt 3) { continue }
        switch ($p[0]) {
            'OK'   { Write-Tag ' OK ' Green $p[1] $p[2] }
            'WARN' { Write-Tag 'WARN' Yellow $p[1] $p[2] }
            default {
                $hint = $p[2]
                if ($hint -match 'running scripts is disabled') { $hint = 'blocked by the PowerShell execution policy (npm.ps1) - run Enviro Easy again without -SkipPolicy' }
                Write-Tag 'FAIL' Red $p[1] $hint
            }
        }
    }
}

#endregion

#region ---------- interactive menu ----------

function Show-ToolPicker {
    Write-Host ''
    Write-Host '  Which of these do you have installed?' -ForegroundColor Cyan
    $i = 1
    foreach ($t in $script:Tools) { Write-Host ('    {0}) {1}' -f $i, $t.Label); $i++ }
    Write-Host ''
    while ($true) {
        $answer = ([string](Read-Host '  Type the numbers, separated by commas (example: 1,2,4) - or A for all')).Trim()
        if ($answer -ieq 'a' -or $answer -ieq 'all') { return @($script:Tools) }
        $picked = New-Object System.Collections.Generic.List[object]
        $ok = [bool]$answer
        foreach ($n in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
            $idx = 0
            if ([int]::TryParse($n, [ref]$idx) -and $idx -ge 1 -and $idx -le $script:Tools.Count) {
                $t = $script:Tools[$idx - 1]
                if (-not $picked.Contains($t)) { $picked.Add($t) }
            }
            else { $ok = $false }
        }
        if ($ok -and $picked.Count -gt 0) { return $picked.ToArray() }
        Write-Host '  Please type numbers from the list, like 1,3,4 - or A.' -ForegroundColor Yellow
    }
}

function Show-MainMenu {
    <# Returns a hashtable of parameters for Invoke-EnviroEasy, or $null to quit. #>
    Write-Host ''
    Write-Host ('  Enviro Easy {0}' -f $script:Version) -ForegroundColor Cyan
    Write-Host '  Fixes "node / npm / python / java is not recognized" on Windows.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  What would you like to do?' -ForegroundColor Cyan
    Write-Host '    1) Set up my PATH'
    Write-Host '    2) Preview only - show what would change, change nothing'
    Write-Host '    3) Undo the last change'
    Write-Host '    Q) Quit'
    $main = Read-Choice -Prompt '  Your choice' -Valid @('1', '2', '3', 'Q') -Default '1'
    if ($main -eq 'Q') { return $null }
    if ($main -eq '3') { return @{ Restore = $true } }

    Write-Host ''
    Write-Host '  Which tools should I look for?' -ForegroundColor Cyan
    Write-Host '    A) All of them (recommended)'
    Write-Host '    P) Let me pick the ones I have installed'
    $which = Read-Choice -Prompt '  Your choice' -Valid @('A', 'P') -Default 'A'
    $tools = @($script:Tools)
    if ($which -eq 'P') { $tools = @(Show-ToolPicker) }

    Write-Host ''
    Write-Host '  Where should I look?' -ForegroundColor Cyan
    Write-Host '    1) Common install folders and settings (fast, recommended)'
    Write-Host '    2) Search my whole C: drive too (a few minutes; finds tools in unusual folders)'
    Write-Host '    3) Search the ENTIRE computer, every drive (slowest)'
    $where = Read-Choice -Prompt '  Your choice' -Valid @('1', '2', '3') -Default '1'
    $search = @{ '1' = 'Common'; '2' = 'C'; '3' = 'All' }[$where]

    Write-Host ''
    Write-Host '  Which environment variables should I update?' -ForegroundColor Cyan
    Write-Host '    1) Both System and User variables (recommended; asks for administrator permission)'
    Write-Host '    2) Only my own User variables (no administrator needed)'
    $scopeChoice = Read-Choice -Prompt '  Your choice' -Valid @('1', '2') -Default '1'
    $scope = 'Both'
    if ($scopeChoice -eq '2') { $scope = 'User' }

    $result = @{ Scope = $scope; Search = $search; Tool = @($tools | ForEach-Object { $_.Key }) }
    if ($main -eq '2') { $result['DryRun'] = $true }
    return $result
}

function Select-Candidates {
    # Lets the user choose which of several installs go on PATH. Returns the chosen roots.
    param($Tool, [string[]]$Candidates)
    Write-Host ''
    Write-Host ("  {0} - found {1} installs. Which one should go on PATH?" -f $Tool.Label, $Candidates.Count) -ForegroundColor Cyan
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $note = ''
        if ($i -eq 0) { $note = '   (best match)' }
        Write-Host ('    {0}) {1}{2}' -f ($i + 1), $Candidates[$i], $note)
    }
    Write-Host '    A) Add all of them'
    Write-Host '    S) Skip this tool'
    $valid = @(1..$Candidates.Count | ForEach-Object { "$_" }) + @('A', 'S')
    $c = Read-Choice -Prompt '  Your choice' -Valid $valid -Default '1'
    if ($c -ieq 'S') { return @() }
    if ($c -ieq 'A') { return $Candidates }
    return @($Candidates[[int]$c - 1])
}

#endregion

#region ---------- main ----------

function Start-ElevatedSelf {
    param([string]$ArgumentString)
    $ps = Join-P $PSHOME 'powershell.exe'
    $p = Start-Process -FilePath $ps -ArgumentList $ArgumentString -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}

function Invoke-EnviroEasy {
    [CmdletBinding()]
    param(
        [string]$Scope = 'Both',
        [string[]]$Tool = @('All'),
        [string]$Search = 'Common',
        [switch]$Pick,
        [switch]$DryRun,
        [switch]$AllVersions,
        [switch]$Force,
        [switch]$SkipPolicy,
        [switch]$Yes,
        [switch]$Restore,
        [string]$BackupFile,
        [switch]$Elevated
    )

    $script:LastExit = 0
    $isTest = [bool]$script:TestKeys
    $interactive = (-not $Yes) -and (-not $isTest) -and (Test-Interactive)
    $scopes = @(Resolve-Scopes -Scope $Scope)
    $selected = @(Resolve-ToolSelection -Names $Tool)
    $scopeText = ($scopes | ForEach-Object { Get-ScopeLabel $_ }) -join ' + '

    Write-Host ''
    Write-Host ('  Enviro Easy {0} - Windows developer environment setup' -f $script:Version) -ForegroundColor Cyan
    Write-Host ('  Variables : {0}' -f $scopeText) -ForegroundColor Gray
    if ($Restore) { Write-Host '  Mode      : RESTORE (undo the last change)' -ForegroundColor Gray }
    else {
        $where = @{ Common = 'common install folders and settings'; C = 'common places + a deep search of drive C:'; All = 'common places + a deep search of EVERY drive' }[$Search]
        Write-Host ('  Searching : {0}' -f $where) -ForegroundColor Gray
        if ($DryRun) { Write-Host '  Mode      : DRY RUN - nothing will be changed' -ForegroundColor Yellow }
        else { Write-Host '  Mode      : APPLY' -ForegroundColor Gray }
    }
    Write-Host ''

    if ($Pick -and $interactive) { $selected = @(Show-ToolPicker) }

    # ----- administrator rights are needed to write the System variables -----
    $needsAdmin = ($scopes -contains 'Machine') -and (-not $DryRun) -and (-not $isTest) -and (-not (Test-IsAdmin))
    if ($needsAdmin) {
        Write-Host '  Changing the System variables needs administrator permission.' -ForegroundColor Yellow
        Write-Host '  Windows will now ask you to allow it - please click Yes.' -ForegroundColor Yellow
        $argText = Format-RelaunchArguments -ScriptPath $script:SelfPath -Scope $Scope -ToolKeys @($selected | ForEach-Object { $_.Key }) -Search $Search `
            -AllVersions ([bool]$AllVersions) -Force ([bool]$Force) -SkipPolicy ([bool]$SkipPolicy) -Yes ([bool]$Yes) -Restore ([bool]$Restore) -BackupFile $BackupFile
        try {
            $script:LastExit = Start-ElevatedSelf -ArgumentString $argText
            Write-Host ''
            Write-Host '  The administrator window has finished.' -ForegroundColor Gray
            return
        }
        catch {
            Write-Host ''
            Write-Host '  Administrator permission was not given. Continuing with your User variables only.' -ForegroundColor Yellow
            Write-Host '  (Run again and click Yes on the Windows prompt to update the System variables too.)' -ForegroundColor Yellow
            Write-Host ''
            $scopes = @('User')
        }
    }

    # ----- undo -----
    if ($Restore) {
        $targets = $scopes
        if ($BackupFile) { $targets = @((Read-BackupDoc -File $BackupFile).Scope) }
        $errors = New-Object System.Collections.Generic.List[string]
        $restored = 0
        foreach ($s in $targets) {
            try { Restore-EnvBackup -Scope $s -BackupFile $BackupFile -DryRun ([bool]$DryRun); $restored++ }
            catch { $errors.Add($_.Exception.Message); Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Yellow }
        }
        if ($restored -eq 0) { throw ($errors -join ' ') }
        if (-not $DryRun) {
            Write-Host ''
            Write-Host '  Close and reopen terminals, VS Code and Android Studio to pick up the change.' -ForegroundColor Yellow
        }
        return
    }

    # ----- find the tools -----
    $effective = @(Get-EffectivePath)
    Write-Host '  Scanning...' -ForegroundColor DarkGray

    $quick = @{}
    foreach ($t in $selected) { $quick[$t.Key] = Find-ToolRoots -Tool $t -Effective $effective -AllVersions ([bool]$AllVersions) }

    if ($Search -eq 'Common' -and $interactive) {
        $missing = @($selected | Where-Object { $quick[$_.Key].Roots.Count -eq 0 })
        if ($missing.Count -gt 0) {
            Write-Host ''
            Write-Host ("  Not found in the common places: {0}." -f (($missing | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
            $ans = Read-Choice -Prompt '  Search your whole C: drive for them? (takes a few minutes) [y/N]' -Valid @('y', 'n') -Default 'n'
            if ($ans -ieq 'y') { $Search = 'C' }
        }
    }

    $deep = @{}
    if ($Search -ne 'Common') {
        $need = @($selected | Where-Object { $quick[$_.Key].Source -ne 'PATH' })
        if ($need.Count -gt 0) {
            $roots = @(Get-FixedDrives)
            if ($Search -eq 'C') { $roots = @(($env:SystemDrive + '\')) }
            Write-Host ("  Deep search of {0} - this can take a few minutes..." -f ($roots -join ' ')) -ForegroundColor Gray
            $deep = Invoke-DeepScan -Roots $roots -Tools $need
        }
    }

    $state = @{}
    foreach ($s in $scopes) {
        $cur = @(Split-PathList (Get-EnvRaw -Scope $s -Name 'Path').Value)
        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($e in $cur) { [void]$set.Add((ConvertTo-NormalPath $e)) }
        $state[$s] = [pscustomobject]@{ Current = $cur; Set = $set; Wanted = (New-Object System.Collections.Generic.List[string]); Vars = [ordered]@{} }
    }
    $foundTools = New-Object System.Collections.Generic.List[object]
    $folders = New-Object System.Collections.Generic.List[string]

    Write-Host ''
    foreach ($t in $selected) {
        $deepHits = @()
        if ($deep.ContainsKey($t.Key)) { $deepHits = @($deep[$t.Key]) }
        $res = Find-ToolRoots -Tool $t -Effective $effective -AllVersions ([bool]$AllVersions) -Deep $deepHits
        if ($res.Roots.Count -eq 0) {
            $detail = 'not found'
            if ($t.MissingNote) { $detail += ' (' + $t.MissingNote + ')' }
            elseif ($Search -eq 'Common') { $detail += ' (run again and choose a deeper search to look everywhere)' }
            Write-Tag 'MISS' DarkYellow $t.Name $detail
            continue
        }
        $roots = @($res.Roots)
        if ($res.Source -eq 'search' -and $interactive -and -not $AllVersions -and $res.Candidates.Count -gt 1) {
            $roots = @(Select-Candidates -Tool $t -Candidates $res.Candidates)
            if ($roots.Count -eq 0) { Write-Tag 'SKIP' DarkYellow $t.Name 'skipped by you'; continue }
        }
        $foundTools.Add($t)

        $binDirs = New-Object System.Collections.Generic.List[string]
        foreach ($root in $roots) { foreach ($d in @(Resolve-ToolDirs -Tool $t -Root $root)) { $binDirs.Add($d) } }
        $user = Get-ToolUserDirs -Tool $t
        foreach ($c in $user.ToCreate) { $folders.Add($c) }
        $userDirs = @($user.Existing) + @($user.ToCreate)

        $lines = New-Object System.Collections.Generic.List[string]
        $needed = $false
        $dirScopes = [ordered]@{}
        foreach ($s in $scopes) {
            $dirs = @($binDirs.ToArray())
            if ($s -eq 'User') { $dirs += $userDirs }
            foreach ($d in @($dirs | Select-Object -Unique)) {
                if ($state[$s].Set.Contains($d)) { continue }
                if (-not $dirScopes.Contains($d)) { $dirScopes[$d] = New-Object System.Collections.Generic.List[string] }
                $dirScopes[$d].Add((Get-ScopeLabel $s))
                $state[$s].Wanted.Add($d)
                $needed = $true
            }
            if ($t.SetVar) {
                $current = Get-EnvScopeValue -Scope $s -Name $t.SetVar
                $valid = $current -and (Test-Path -LiteralPath (Join-P $current $t.Marker) -PathType Leaf)
                if ($Force -or -not $valid) {
                    $state[$s].Vars[$t.SetVar] = $roots[0]
                    $lines.Add(('           + {0} = {1}   ({2})' -f $t.SetVar, $roots[0], (Get-ScopeLabel $s)))
                    $needed = $true
                }
            }
        }
        $shown = New-Object System.Collections.Generic.List[string]
        foreach ($c in $user.ToCreate) { $shown.Add(('           + create folder  {0}' -f $c)) }
        foreach ($d in $dirScopes.Keys) { $shown.Add(('           + PATH  {0}   ({1})' -f $d, ($dirScopes[$d] -join ', '))) }
        foreach ($l in $lines) { $shown.Add($l) }

        $rootText = ($roots -join '; ')
        if (-not $needed) {
            $how = if ($res.Source -eq 'PATH') { 'already on PATH' } else { 'already configured' }
            Write-Tag ' OK ' Green $t.Name ('{0}  ({1})' -f $rootText, $how)
        }
        else {
            Write-Tag 'ADD ' Cyan $t.Name $rootText
            foreach ($l in $shown) { Write-Host $l -ForegroundColor DarkCyan }
        }
    }

    # ----- PowerShell execution policy (npm.ps1) -----
    $policy = $null
    $nodeFound = @($foundTools | Where-Object { $_.Key -eq 'Node' }).Count -gt 0
    if ($nodeFound -and -not $SkipPolicy) {
        $policy = Get-PolicyPlan -Scopes $scopes -List @(Get-PolicyList)
        if (-not $policy.State.Blocking) {
            Write-Tag ' OK ' Green 'PowerShell' ("execution policy is {0} - npm can run in Windows PowerShell" -f $policy.State.Effective)
        }
        elseif ($policy.State.Gpo) {
            Write-Tag 'WARN' Yellow 'PowerShell' ("execution policy {0} is forced by your organization ({1}); npm will not run in Windows PowerShell. Use Command Prompt, or ask your IT admin." -f $policy.State.Effective, $policy.State.Source)
        }
        else {
            Write-Tag 'ADD ' Cyan 'PowerShell' ("execution policy is {0} - Windows PowerShell cannot run npm" -f $policy.State.Effective)
            foreach ($tg in $policy.Targets) { Write-Host ("           + execution policy ({0}): {1} -> RemoteSigned" -f $tg.PolicyScope, $tg.Previous) -ForegroundColor DarkCyan }
            if ($policy.StillBlockedAfter) { Write-Host '           ! still blocked after this - another policy setting wins' -ForegroundColor Yellow }
        }
    }

    Write-Host ''
    $plans = @{}
    $pathCount = 0
    $varCount = 0
    foreach ($s in $scopes) {
        $plans[$s] = Add-PathEntries -Current $state[$s].Current -Effective @($state[$s].Set) -Wanted $state[$s].Wanted.ToArray()
        $pathCount += $plans[$s].Added.Count
        $varCount += $state[$s].Vars.Count
    }
    $policyCount = 0
    if ($policy) { $policyCount = @($policy.Targets).Count }
    $folderCount = @($folders | Select-Object -Unique).Count

    if ($pathCount -eq 0 -and $varCount -eq 0 -and $policyCount -eq 0 -and $folderCount -eq 0) {
        if ($foundTools.Count -eq 0) { Write-Host '  No supported tools were found. Install them first, then run this again.' -ForegroundColor Yellow }
        else { Write-Host '  Nothing to change - everything that was found is already set up.' -ForegroundColor Green }
        return
    }

    $summary = '{0} PATH entr{1}, {2} variable{3}{4}' -f $pathCount, $(if ($pathCount -eq 1) { 'y' } else { 'ies' }), $varCount, $(if ($varCount -eq 1) { '' } else { 's' }), $(if ($policyCount -gt 0) { ' and the PowerShell execution policy' } else { '' })

    if ($DryRun) {
        Write-Host ("  Dry run: {0} would be changed. Nothing was changed." -f $summary) -ForegroundColor Yellow
        Write-Host '  Run again without -DryRun to apply.' -ForegroundColor Yellow
        return
    }

    if ($interactive) {
        $go = Read-Choice -Prompt ("  Apply these changes ({0})? [Y/n]" -f $summary) -Valid @('y', 'n') -Default 'y'
        if ($go -ieq 'n') { Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }
    }

    # ----- apply -----
    foreach ($f in @($folders | Select-Object -Unique)) { [void](New-Item -ItemType Directory -Path $f -Force) }
    $backups = New-Object System.Collections.Generic.List[string]
    $allVarNames = New-Object System.Collections.Generic.List[string]
    foreach ($s in $scopes) {
        $vars = $state[$s].Vars
        $policyTarget = $null
        if ($policy) { $policyTarget = @($policy.Targets | Where-Object { $_.Scope -eq $s }) | Select-Object -First 1 }
        if ($plans[$s].Added.Count -eq 0 -and $vars.Count -eq 0 -and -not $policyTarget) { continue }

        $backups.Add((Save-Backup -Scope $s -VarNames @($vars.Keys) `
            -PolicyScope $(if ($policyTarget) { $policyTarget.PolicyScope } else { '' }) -PolicyPrevious $(if ($policyTarget) { $policyTarget.Previous } else { '' })))

        if ($plans[$s].Added.Count -gt 0) {
            $existing = Get-EnvRaw -Scope $s -Name 'Path'
            Set-EnvRaw -Scope $s -Name 'Path' -Value ($plans[$s].List -join ';') -Kind $existing.Kind
        }
        foreach ($name in $vars.Keys) {
            Set-EnvRaw -Scope $s -Name $name -Value $vars[$name] -Kind ([Microsoft.Win32.RegistryValueKind]::String)
            $allVarNames.Add($name)
        }
    }
    if ($policy -and @($policy.Targets).Count -gt 0) { Update-PolicyTargets -Targets $policy.Targets }
    Send-EnvironmentChange
    Update-ProcessEnvironment -VarNames @($allVarNames | Select-Object -Unique)

    Write-Host ("  Done. Changed: {0}." -f $summary) -ForegroundColor Green
    foreach ($b in $backups) { Write-Host "  Backup saved: $b" -ForegroundColor DarkGray }
    Write-Host '  To undo:      run Undo-Last-Change.bat  (or  EnviroEasy.ps1 -Restore)' -ForegroundColor DarkGray

    if (-not $isTest) {
        Write-Host ''
        Write-Host '  Checking in Command Prompt...' -ForegroundColor DarkGray
        Write-Host ''
        foreach ($t in $foundTools) { Invoke-Verify -Tool $t }
        Write-Host ''
        Write-Host '  Checking in a new Windows PowerShell...' -ForegroundColor DarkGray
        Write-Host ''
        Invoke-PowerShellCheck -Tools $foundTools.ToArray()
    }

    Write-Host ''
    Write-Host '  Close and reopen terminals, VS Code and Android Studio so they see the new PATH.' -ForegroundColor Yellow
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        if ($PSBoundParameters.Count -eq 0 -and (Test-Interactive)) {
            $chosen = Show-MainMenu
            if ($chosen) { Invoke-EnviroEasy @chosen }
        }
        else { Invoke-EnviroEasy @PSBoundParameters }
        $exitCode = $script:LastExit
    }
    catch {
        Write-Host ''
        Write-Host ('  ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        $exitCode = 1
    }
    if ($Elevated -and (Test-Interactive) -and -not $Yes) {
        Write-Host ''
        [void](Read-Host '  Press Enter to close this window')
    }
    exit $exitCode
}

#endregion
