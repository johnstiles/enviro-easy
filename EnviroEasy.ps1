#Requires -Version 5.1
<#
.SYNOPSIS
    Enviro Easy - finds the developer tools installed on this PC and fixes your
    PATH and *_HOME environment variables for you.

.DESCRIPTION
    Detects Node.js (npm), Python (pip), Git, Java JDK, Android SDK, Flutter,
    Dart, Maven and Gradle - including installs in non-default folders - and adds
    whatever is missing to your PATH. It never removes anything, never adds
    duplicates, keeps %VARIABLE% entries exactly as they were, and saves a backup
    first so every change can be undone with -Restore.

    Detection order for each tool:
      1. Already on PATH (reported as OK; only missing companion folders such as
         Python's Scripts are added).
      2. Environment variables (JAVA_HOME, ANDROID_HOME, FLUTTER_ROOT, ...).
      3. Windows registry install records (+ the Python "py" launcher).
      4. Well-known install folders on every fixed drive.

    Nothing is scanned recursively, so it is fast and will not pick up random
    copies from unrelated folders.

.PARAMETER Scope
    User (default)   Changes only your own account. No administrator needed.
    Machine          Changes every user on this PC. Needs an administrator prompt.

.PARAMETER Tool
    Limit the run to some tools. Default: All.
    Node, Python, Git, Java, Android, Flutter, Dart, Maven, Gradle

.PARAMETER DryRun
    Show what would change without changing anything.

.PARAMETER AllVersions
    Add every version found instead of only the newest one.

.PARAMETER Force
    Overwrite JAVA_HOME / ANDROID_HOME even when they already point somewhere valid.

.PARAMETER Restore
    Undo the last run: put PATH and the variables back from the newest backup.

.PARAMETER BackupFile
    With -Restore: use this specific backup file instead of the newest one.

.EXAMPLE
    .\EnviroEasy.ps1 -DryRun
    Preview the changes.

.EXAMPLE
    .\EnviroEasy.ps1 -Tool Java,Android
    Only fix Java and the Android SDK.

.EXAMPLE
    .\EnviroEasy.ps1 -Restore
    Undo the last change.
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [ValidateSet('All', 'Node', 'Python', 'Git', 'Java', 'Android', 'Flutter', 'Dart', 'Maven', 'Gradle')]
    [string[]]$Tool = @('All'),

    [switch]$DryRun,
    [switch]$AllVersions,
    [switch]$Force,
    [switch]$Restore,
    [string]$BackupFile
)

Set-StrictMode -Version 2.0

$script:Version   = '1.0.0'
$script:TestKey   = $null   # tests only: a registry key used instead of the real environment key
$script:BackupDir = $null   # tests only: overrides the backup folder

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

function Write-Tag {
    param([string]$Tag, [ConsoleColor]$Color, [string]$Name, [string]$Detail)
    Write-Host ('  [{0}] ' -f $Tag) -ForegroundColor $Color -NoNewline
    Write-Host ($Name.PadRight(10)) -NoNewline
    Write-Host $Detail -ForegroundColor Gray
}

#endregion

#region ---------- environment storage (registry) ----------

function Open-EnvKey {
    param([string]$Scope, [bool]$Writable = $false)
    if ($script:TestKey) { return $script:TestKey }
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
    finally { if (-not $script:TestKey) { $key.Dispose() } }
}

function Set-EnvRaw {
    param([string]$Scope, [string]$Name, [string]$Value, $Kind)
    if (-not $Kind) { $Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $key = Open-EnvKey -Scope $Scope -Writable $true
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { if (-not $script:TestKey) { $key.Dispose() } }
}

function Remove-EnvRaw {
    param([string]$Scope, [string]$Name)
    $key = Open-EnvKey -Scope $Scope -Writable $true
    try { $key.DeleteValue($Name, $false) }
    finally { if (-not $script:TestKey) { $key.Dispose() } }
}

function Get-EnvValue {
    # Effective, expanded value of a variable (User beats Machine, then this process).
    param([string]$Name)
    foreach ($s in @('User', 'Machine')) {
        $raw = (Get-EnvRaw -Scope $s -Name $Name).Value
        if ($raw) { return [Environment]::ExpandEnvironmentVariables([string]$raw) }
        if ($script:TestKey) { break }
    }
    if (-not $script:TestKey) {
        $p = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if ($p) { return $p }
    }
    return $null
}

function Get-EffectivePath {
    # Every folder that is on PATH for new processes (Machine first, then User), normalized.
    $scopes = @('Machine', 'User')
    if ($script:TestKey) { $scopes = @('User') }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($s in $scopes) {
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
    if ($script:TestKey) { return }
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
    if ($script:TestKey) { return }
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

#region ---------- backups ----------

function Get-BackupDir {
    if ($script:BackupDir) { return $script:BackupDir }
    return (Join-P $env:LOCALAPPDATA 'EnviroEasy\backups')
}

function Save-Backup {
    param([string]$Scope, [string[]]$VarNames, [string]$Prefix = 'backup')
    $dir = Get-BackupDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $pathRaw = Get-EnvRaw -Scope $Scope -Name 'Path'
    $vars = [ordered]@{}
    foreach ($n in $VarNames) {
        $r = Get-EnvRaw -Scope $Scope -Name $n
        $vars[$n] = [ordered]@{ Value = $r.Value; Kind = [string]$r.Kind }
    }
    $doc = [ordered]@{
        Tool      = 'EnviroEasy'
        Version   = $script:Version
        Scope     = $Scope
        Created   = (Get-Date).ToString('s')
        Path      = [ordered]@{ Value = $pathRaw.Value; Kind = [string]$pathRaw.Kind }
        Variables = $vars
    }
    $file = Join-P $dir ('{0}-{1}-{2}.json' -f $Prefix, $Scope, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
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
    if (-not $file -or -not (Test-Path -LiteralPath $file)) {
        throw "No $Scope backup found in $(Get-BackupDir). Nothing to restore."
    }

    $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($doc.Tool -ne 'EnviroEasy') { throw "'$file' is not an Enviro Easy backup." }
    if ($doc.Scope -ne $Scope) { throw "That backup is for the $($doc.Scope) scope. Run again with -Scope $($doc.Scope)." }

    Write-Host "  Backup : $file" -ForegroundColor Gray
    Write-Host "  Taken  : $($doc.Created)" -ForegroundColor Gray
    Write-Host ''
    $varNames = @($doc.Variables.PSObject.Properties | ForEach-Object { $_.Name })

    if ($DryRun) {
        Write-Host '  Dry run - would restore PATH' -ForegroundColor Yellow -NoNewline
        if ($varNames.Count) { Write-Host (' and ' + ($varNames -join ', ')) -ForegroundColor Yellow -NoNewline }
        Write-Host '. Nothing was changed.' -ForegroundColor Yellow
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
            Write-Host "  Removed variable $n (it did not exist before)" -ForegroundColor Green
        }
        else {
            Set-EnvRaw -Scope $Scope -Name $n -Value ([string]$entry.Value) -Kind $entry.Kind
            Write-Host "  Restored variable $n" -ForegroundColor Green
        }
    }
    Send-EnvironmentChange
    Write-Host '  Restored PATH.' -ForegroundColor Green
    Write-Host "  (The state before this restore was saved to $safety)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Close and reopen terminals, VS Code and Android Studio to pick up the change.' -ForegroundColor Yellow
}

#endregion

#region ---------- tool catalogue ----------

function New-ToolSpec {
    param(
        [string]$Key, [string]$Name, [string]$Marker, [string[]]$Bins,
        [string[]]$Extras = @(), [string[]]$EnvVars = @(), [string]$SetVar = '',
        [string[]]$Registry = @(), [string[]]$Patterns = @(), [string[]]$Verify = @(),
        [scriptblock]$ExtraRoots = $null, [string]$MissingNote = ''
    )
    [pscustomobject]@{
        Key = $Key; Name = $Name; Marker = $Marker; Bins = $Bins; Extras = $Extras
        EnvVars = $EnvVars; SetVar = $SetVar; Registry = $Registry; Patterns = $Patterns
        Verify = $Verify; ExtraRoots = $ExtraRoots; MissingNote = $MissingNote
    }
}

# Notes on the fields:
#   Marker    file (relative to the install root) that proves the tool is really there
#   Bins      folders (relative to the root) that belong on PATH; 'a|b' = first one that exists
#   Extras    extra folders (absolute, may contain * and %VARS%) added when they exist
#   Registry  'Key\Under\SOFTWARE|ValueName' install records (HKLM, HKLM\WOW6432Node, HKCU)
#   Patterns  well-known install folders; {DRIVES} expands to every fixed drive (C:\, D:\, ...)
#   Verify    'command|arguments' run at the end; an empty argument only checks it resolves

$script:PyLauncherRoots = {
    $py = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { return }
    try { $out = @(& $py.Source -0p 2>$null) } catch { return }
    foreach ($line in $out) {
        if ("$line" -match '([A-Za-z]:\\.*?\.exe)') { Split-Path $Matches[1] -Parent }
    }
}

$script:Tools = @(
    (New-ToolSpec -Key 'Node' -Name 'Node.js' -Marker 'node.exe' -Bins @('') `
        -Extras @('%APPDATA%\npm') -EnvVars @('NVM_SYMLINK') `
        -Registry @('Node.js|InstallPath') `
        -Patterns @('%ProgramFiles%\nodejs', '%ProgramFiles(x86)%\nodejs', '%LOCALAPPDATA%\Programs\nodejs', '{DRIVES}nodejs', '{DRIVES}Program Files\nodejs') `
        -Verify @('node|--version', 'npm|--version', 'npx|--version')),

    (New-ToolSpec -Key 'Python' -Name 'Python' -Marker 'python.exe' -Bins @('', 'Scripts') `
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

    (New-ToolSpec -Key 'Android' -Name 'Android' -Marker 'platform-tools\adb.exe' `
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

#endregion

#region ---------- detection ----------

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
    <# Returns the install root(s) to use for a tool, and where they came from. #>
    param($Tool, [string[]]$Effective, [bool]$AllVersions)

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
            return [pscustomobject]@{ Roots = @($root); Source = 'PATH' }
        }
    }

    # 2) search: env vars first, then registry, known folders, extras
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

    if ($cands.Count -eq 0) { return [pscustomobject]@{ Roots = @(); Source = '' } }

    $sorted = @($cands | Sort-Object -Property @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Ver'; Descending = $true }, 'Path')
    $roots = @($sorted | ForEach-Object { $_.Path })
    if (-not $AllVersions) { $roots = @($roots[0]) }
    return [pscustomobject]@{ Roots = $roots; Source = 'search' }
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
    foreach ($extra in $Tool.Extras) {
        foreach ($d in @(Expand-Pattern -Pattern $extra)) { $dirs.Add((ConvertTo-NormalPath $d)) }
    }
    return $dirs.ToArray()
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

#endregion

#region ---------- verification ----------

function Invoke-Verify {
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

#endregion

#region ---------- main ----------

function Invoke-EnviroEasy {
    [CmdletBinding()]
    param(
        [string]$Scope = 'User',
        [string[]]$Tool = @('All'),
        [switch]$DryRun,
        [switch]$AllVersions,
        [switch]$Force,
        [switch]$Restore,
        [string]$BackupFile
    )

    $isTest = [bool]$script:TestKey
    Write-Host ''
    Write-Host ('  Enviro Easy {0} - Windows developer environment setup' -f $script:Version) -ForegroundColor Cyan
    if ($Scope -eq 'Machine') { Write-Host '  Scope : Machine (all users on this PC)' -ForegroundColor Gray }
    else { Write-Host '  Scope : User (only your account)' -ForegroundColor Gray }
    if ($Restore) { Write-Host '  Mode  : RESTORE (undo the last change)' -ForegroundColor Gray }
    elseif ($DryRun) { Write-Host '  Mode  : DRY RUN - nothing will be changed' -ForegroundColor Yellow }
    else { Write-Host '  Mode  : APPLY' -ForegroundColor Gray }
    Write-Host ''

    if ($Scope -eq 'Machine' -and -not $isTest -and -not (Test-IsAdmin)) {
        throw "Scope 'Machine' needs administrator rights. Open an administrator prompt and run it again, or use the default User scope."
    }

    if ($Restore) {
        Restore-EnvBackup -Scope $Scope -BackupFile $BackupFile -DryRun ([bool]$DryRun)
        return
    }

    $selected = @($script:Tools)
    if (-not ($Tool -contains 'All')) { $selected = @($script:Tools | Where-Object { $Tool -contains $_.Key }) }

    $effective = @(Get-EffectivePath)
    $wanted = New-Object System.Collections.Generic.List[string]
    $varsToSet = [ordered]@{}
    $foundTools = New-Object System.Collections.Generic.List[object]
    $effectiveSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $effective) { [void]$effectiveSet.Add($e) }

    Write-Host '  Scanning...' -ForegroundColor DarkGray
    Write-Host ''

    foreach ($t in $selected) {
        $res = Find-ToolRoots -Tool $t -Effective $effective -AllVersions ([bool]$AllVersions)
        if ($res.Roots.Count -eq 0) {
            $detail = 'not found'
            if ($t.MissingNote) { $detail += ' (' + $t.MissingNote + ')' }
            Write-Tag 'MISS' DarkYellow $t.Name $detail
            continue
        }
        $foundTools.Add($t)

        $toolDirs = New-Object System.Collections.Generic.List[string]
        foreach ($root in $res.Roots) { foreach ($d in @(Resolve-ToolDirs -Tool $t -Root $root)) { $toolDirs.Add($d) } }
        $missing = @($toolDirs | Where-Object { -not $effectiveSet.Contains($_) } | Select-Object -Unique)

        $pendingVar = $null
        if ($t.SetVar) {
            $current = Get-EnvValue -Name $t.SetVar
            $valid = $current -and (Test-Path -LiteralPath (Join-P $current $t.Marker) -PathType Leaf)
            if ($Force -or -not $valid) { $pendingVar = $res.Roots[0] }
        }

        $rootText = ($res.Roots -join '; ')
        if ($missing.Count -eq 0 -and -not $pendingVar) {
            $how = if ($res.Source -eq 'PATH') { 'already on PATH' } else { 'already configured' }
            Write-Tag ' OK ' Green $t.Name ('{0}  ({1})' -f $rootText, $how)
        }
        else {
            Write-Tag 'ADD ' Cyan $t.Name $rootText
            foreach ($m in $missing) { Write-Host ('           + PATH  ' + $m) -ForegroundColor DarkCyan; $wanted.Add($m) }
            if ($pendingVar) {
                Write-Host ('           + {0} = {1}' -f $t.SetVar, $pendingVar) -ForegroundColor DarkCyan
                $varsToSet[$t.SetVar] = $pendingVar
            }
        }
    }

    Write-Host ''
    $plan = Add-PathEntries -Current (Split-PathList (Get-EnvRaw -Scope $Scope -Name 'Path').Value) -Effective $effective -Wanted $wanted.ToArray()

    if ($plan.Added.Count -eq 0 -and $varsToSet.Count -eq 0) {
        if ($foundTools.Count -eq 0) { Write-Host '  No supported tools were found. Install them first, then run this again.' -ForegroundColor Yellow }
        else { Write-Host '  Nothing to change - everything that was found is already set up.' -ForegroundColor Green }
        return
    }

    if ($DryRun) {
        Write-Host ('  Dry run: {0} PATH entr{1} and {2} variable{3} would be added. Nothing was changed.' -f `
            $plan.Added.Count, $(if ($plan.Added.Count -eq 1) { 'y' } else { 'ies' }), $varsToSet.Count, $(if ($varsToSet.Count -eq 1) { '' } else { 's' })) -ForegroundColor Yellow
        Write-Host '  Run again without -DryRun to apply.' -ForegroundColor Yellow
        return
    }

    # ----- apply -----
    $backup = Save-Backup -Scope $Scope -VarNames @($varsToSet.Keys)

    if ($plan.Added.Count -gt 0) {
        $existing = Get-EnvRaw -Scope $Scope -Name 'Path'
        Set-EnvRaw -Scope $Scope -Name 'Path' -Value ($plan.List -join ';') -Kind $existing.Kind
    }
    foreach ($name in $varsToSet.Keys) {
        Set-EnvRaw -Scope $Scope -Name $name -Value $varsToSet[$name] -Kind ([Microsoft.Win32.RegistryValueKind]::String)
    }
    Send-EnvironmentChange
    Update-ProcessEnvironment -VarNames @($varsToSet.Keys)

    Write-Host ('  Done. Added {0} PATH entr{1} and set {2} variable{3}.' -f `
        $plan.Added.Count, $(if ($plan.Added.Count -eq 1) { 'y' } else { 'ies' }), $varsToSet.Count, $(if ($varsToSet.Count -eq 1) { '' } else { 's' })) -ForegroundColor Green
    Write-Host "  Backup saved: $backup" -ForegroundColor DarkGray
    Write-Host '  To undo:      run Undo-Last-Change.bat  (or  EnviroEasy.ps1 -Restore)' -ForegroundColor DarkGray

    if (-not $isTest) {
        Write-Host ''
        Write-Host '  Verifying...' -ForegroundColor DarkGray
        Write-Host ''
        foreach ($t in $foundTools) { Invoke-Verify -Tool $t }
    }

    Write-Host ''
    Write-Host '  Close and reopen terminals, VS Code and Android Studio so they see the new PATH.' -ForegroundColor Yellow
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-EnviroEasy @PSBoundParameters
        exit 0
    }
    catch {
        Write-Host ''
        Write-Host ('  ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

#endregion
