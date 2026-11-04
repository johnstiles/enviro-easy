# Contributing

Thanks for helping make Windows setup less painful!

## Run the tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

They use throw-away registry keys, fake folders and a fake PowerShell execution policy, so they never
touch your real PATH, variables or policy. Please add a test for anything you change.

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
| `Extras` | Per-user folders (absolute, wildcards and `%VARS%` allowed) added to the **User** PATH when they exist |
| `CreateDirs` | Per-user folders that are created when missing (e.g. `%APPDATA%\npm`) |
| `EnvVars` | Variables that may point at the install root (checked first) |
| `SetVar` | A variable to set to the root when it is missing or broken (e.g. `JAVA_HOME`) |
| `Registry` | `Key under SOFTWARE\|Value` install records |
| `Patterns` | Well-known folders; `{DRIVES}` expands to every fixed drive |
| `Verify` | `command\|arguments` to run at the end; empty arguments only checks it resolves |

The tool is then picked up automatically by `-Tool`, the menu, the quick search and the deep search
(the deep search matches the leaf of `Marker`). Add it to the README table too.

## Ground rules

- **Never remove or rewrite existing PATH entries.** The tool is additive on purpose.
- **Recursive drive scans are opt-in only** (`-Search C` / `-Search All`). The default search must stay fast.
- Never change the real execution policy from tests - use the fakes in `tests\Run-Tests.ps1`.
- Keep the script **ASCII-only** (Windows PowerShell 5.1 misreads BOM-less UTF-8) and compatible with Windows PowerShell 5.1.
- Don't download or install anything from the script.
