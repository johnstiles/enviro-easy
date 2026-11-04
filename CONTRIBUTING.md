# Contributing

Thanks for helping make Windows setup less painful!

## Run the tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

They use a throw-away registry key and fake folders, so they never touch your real PATH.
Please add a test for anything you change.

## Add a tool

Tools are declared in the `$script:Tools` list in `EnviroEasy.ps1` with `New-ToolSpec`:

```powershell
(New-ToolSpec -Key 'Go' -Name 'Go' -Marker 'bin\go.exe' -Bins @('bin') `
    -EnvVars @('GOROOT') `
    -Registry @('GoLang|InstallLocation') `
    -Patterns @('%ProgramFiles%\Go', '{DRIVES}Go') `
    -Verify @('go|version'))
```

| Field | Meaning |
|---|---|
| `Marker` | File, relative to the install root, that proves the tool is there |
| `Bins` | Folders (relative to the root) that belong on PATH. `a\|b` = first one that exists |
| `Extras` | Extra absolute folders to add when they exist (wildcards and `%VARS%` allowed) |
| `EnvVars` | Variables that may point at the install root (checked first) |
| `SetVar` | A variable to set to the root when it is missing or broken (e.g. `JAVA_HOME`) |
| `Registry` | `Key under SOFTWARE\|Value` install records |
| `Patterns` | Well-known folders; `{DRIVES}` expands to every fixed drive |
| `Verify` | `command\|arguments` to run at the end; empty arguments only checks it resolves |

Also add the key to the `-Tool` `ValidateSet` at the top of the script, and to the README table.

## Ground rules

- **Never remove or rewrite existing PATH entries.** The tool is additive on purpose.
- **No recursive drive scans.** Keep detection fast and predictable.
- Keep the script **ASCII-only** (Windows PowerShell 5.1 misreads BOM-less UTF-8) and compatible with Windows PowerShell 5.1.
- Don't download or install anything from the script.
