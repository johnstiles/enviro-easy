# Enviro Easy

**One double-click to fix "`node` / `python` / `java` is not recognized as an internal or external command" on Windows.**

Enviro Easy finds the developer tools already installed on your PC - even in
non-default folders - and adds whatever is missing to your `PATH` (and sets
`JAVA_HOME` / `ANDROID_HOME`). It is safe by design: it previews changes, never
removes or duplicates anything, and can undo itself.

```
  Enviro Easy 1.0.0 - Windows developer environment setup
  Scope : User (only your account)
  Mode  : APPLY

  [ OK ] Node.js   C:\Program Files\nodejs  (already on PATH)
  [ADD ] Python    D:\Tools\Python313
           + PATH  D:\Tools\Python313
           + PATH  D:\Tools\Python313\Scripts
  [ADD ] Android   C:\Users\you\AppData\Local\Android\Sdk
           + PATH  C:\Users\you\AppData\Local\Android\Sdk\platform-tools
           + ANDROID_HOME = C:\Users\you\AppData\Local\Android\Sdk
  [MISS] Maven     not found
```

## Quick start

1. **Download** this project (green **Code** button -> **Download ZIP**) and extract it.
   Keep all the files together.
2. Double-click **`Preview-Changes.bat`** to see what would change. Nothing is modified.
3. Double-click **`Setup-Development-Environment.bat`** to apply it.
4. **Close and reopen** your terminals, VS Code and Android Studio.
5. Check it worked:
   ```
   node --version
   npm --version
   python --version
   pip --version
   ```

Made a mistake or changed your mind? Double-click **`Undo-Last-Change.bat`**.

No administrator rights are needed: by default only *your* account's PATH is changed.

## What it detects

| Tool | Added to PATH | Also |
|---|---|---|
| **Node.js** | folder with `node.exe` / `npm` / `npx` | `%APPDATA%\npm` (global npm packages) when it exists |
| **Python** | install folder + `Scripts` (`pip`) | `pip install --user` Scripts folders |
| **Git** | `cmd` folder | |
| **Java JDK** | `bin` | sets `JAVA_HOME` if missing or broken |
| **Android SDK** | `platform-tools` (`adb`), `cmdline-tools\...\bin` (`sdkmanager`), `emulator` | sets `ANDROID_HOME` if missing or broken |
| **Flutter** | `bin` | |
| **Dart** | `bin` (standalone SDK; Flutter already bundles Dart) | |
| **Maven** | `bin` | |
| **Gradle** | `bin` | |

### How it finds them

For each tool, in this order:

1. **Already on PATH** - reported as OK; only missing companions (like Python's `Scripts`) are added.
2. **Environment variables** - `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `FLUTTER_ROOT`, `MAVEN_HOME`, `GRADLE_HOME`, `PYTHONHOME`, ...
3. **Windows registry** install records, plus the Python `py` launcher.
4. **Well-known folders on every fixed drive** (`C:\`, `D:\`, ...), not just `C:\Program Files`.

It does **not** crawl whole drives - that would be slow and could pick up unrelated copies.
If several versions are installed it picks the newest (use `-AllVersions` to add them all).

## Options

Run `Setup-Development-Environment.bat` with options, or call the script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\EnviroEasy.ps1 [options]
```

| Option | What it does |
|---|---|
| `-DryRun` | Show what would change; change nothing. |
| `-Tool Java,Android` | Only handle these tools (`Node`, `Python`, `Git`, `Java`, `Android`, `Flutter`, `Dart`, `Maven`, `Gradle`). |
| `-Scope Machine` | Change PATH for **all users**. Needs an administrator prompt. Default is `User`. |
| `-AllVersions` | Add every version found, not just the newest. |
| `-Force` | Overwrite `JAVA_HOME` / `ANDROID_HOME` even if they already point somewhere valid. |
| `-Restore` | Undo the last run (add `-BackupFile <path>` to pick a specific backup). |

Examples:

```
Setup-Development-Environment.bat -Tool Java,Android
Setup-Development-Environment.bat -Scope Machine        (from an administrator Command Prompt)
```

## Safety

- **Preview first** with `-DryRun` / `Preview-Changes.bat`.
- **Additive only** - existing entries are never removed, reordered, or rewritten.
  `%VARIABLE%` entries stay exactly as you had them (a common bug in PATH scripts is
  expanding them and silently breaking things).
- **No duplicates** - compared ignoring case and trailing slashes, across both your PATH and the system PATH.
- **Automatic backup** before every change, stored in `%LOCALAPPDATA%\EnviroEasy\backups`.
  `-Restore` puts PATH and variables back exactly (and itself saves a backup, so even an undo can be undone).
- **Nothing runs in the background** and nothing is downloaded or installed. It only reads your system and edits environment variables.
- It is one readable script. Please read [`EnviroEasy.ps1`](EnviroEasy.ps1) before running software that changes your system - you should do that for every tool like this one.

## Troubleshooting

**It worked but `node`/`python` still isn't found.**
Already-open terminals keep their old PATH. Close them (and VS Code / Android Studio) and open new ones.

**`python` opens the Microsoft Store.**
Windows ships a Store "stub" named `python.exe`. Enviro Easy puts the real Python *before* it, but you can also
turn the stub off: **Settings -> Apps -> Advanced app settings -> App execution aliases** -> switch off *python.exe* and *python3.exe*.

**A tool shows `[MISS] not found` but it is installed.**
It is probably in an unusual folder. Fix it once by setting the tool's variable (e.g. `JAVA_HOME`, `ANDROID_HOME`,
`FLUTTER_ROOT`) to its install folder and run Enviro Easy again - it checks those first. Or add the folder to
the lists in `$script:Tools` in `EnviroEasy.ps1` (and send a pull request!).

**"Scope 'Machine' needs administrator rights."**
Open *Command Prompt* as administrator and run `Setup-Development-Environment.bat -Scope Machine`. Most people should just use the default.

**PowerShell says scripts are disabled.**
The `.bat` launchers run the script with `-ExecutionPolicy Bypass` for that one run only; your system policy is not changed.
(`Set-ExecutionPolicy` is unrelated to environment variables.)

## Requirements

Windows 10 / 11 with Windows PowerShell 5.1 (built in). Tested on Windows 11. PowerShell 7 is not yet tested.

## Development

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

The tests run against a throw-away registry key and fake install folders - your real PATH is never touched.
See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a tool.

## Roadmap

- `-Clean` to remove PATH entries that point to folders that no longer exist
- Rust, Go, .NET SDK, CMake, Docker CLI, Visual Studio Build Tools
- A tiny GUI
- PowerShell 7 and `winget` / Scoop awareness

## License

[MIT](LICENSE)
