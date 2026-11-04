# Enviro Easy

**One double-click to fix "`node` / `npm` / `python` / `java` is not recognized" on Windows - and to make `npm` work in Windows PowerShell.**

Enviro Easy finds the developer tools already installed on your PC - even in
unusual folders, on any drive - and adds whatever is missing to your **System
*and* User** `PATH` (and sets `JAVA_HOME` / `ANDROID_HOME`). It also fixes the
PowerShell setting that makes `npm` fail with *"running scripts is disabled on
this system"*. It is safe by design: it previews changes, never removes or
duplicates anything, and can undo itself.

```
  Enviro Easy 1.1.0 - Windows developer environment setup
  Variables : System + User
  Searching : common places + a deep search of drive C:

  [ OK ] Node.js    C:\Program Files\nodejs  (already on PATH)
  [ADD ] Python     D:\Tools\Python313
           + PATH  D:\Tools\Python313   (System, User)
           + PATH  D:\Tools\Python313\Scripts   (System, User)
  [ADD ] Android    C:\Users\you\AppData\Local\Android\Sdk
           + PATH  ...\Sdk\platform-tools   (System, User)
           + ANDROID_HOME = C:\Users\you\AppData\Local\Android\Sdk   (System, User)
  [ADD ] PowerShell execution policy is Restricted - Windows PowerShell cannot run npm
           + execution policy (CurrentUser): Undefined -> RemoteSigned
  [MISS] Maven      not found
```

## Quick start

1. **Download** this project (green **Code** button -> **Download ZIP**) and extract it. Keep all files together.
2. Double-click **`Setup-Development-Environment.bat`** and follow the menu:

   ```
   1) Set up my PATH            2) Preview only            3) Undo the last change

   Which tools?     A) all of them        P) let me pick the ones I have installed
   Where to look?   1) common folders     2) my whole C: drive     3) the entire computer
   Which variables? 1) System + User      2) only my User variables
   ```
3. Click **Yes** on the Windows administrator prompt (needed to change the *System* variables).
4. **Close and reopen** your terminals, VS Code and Android Studio.
5. Check it worked - in **both** Command Prompt and Windows PowerShell:
   ```
   node --version
   npm --version
   python --version
   pip --version
   ```

Enviro Easy also runs this check itself at the end, in a fresh Command Prompt *and* a fresh Windows PowerShell.

Changed your mind? Double-click **`Undo-Last-Change.bat`**. Just want to look? **`Preview-Changes.bat`** changes nothing.

## `npm` in Windows PowerShell

On a fresh Windows, `npm` works in Command Prompt but fails in Windows PowerShell:

```
npm : File C:\Program Files\nodejs\npm.ps1 cannot be loaded because running scripts is disabled on this system.
```

That is not a PATH problem - it is PowerShell's **execution policy** (`Restricted` by default on Windows 10/11).
When Node.js is found, Enviro Easy sets the policy to **`RemoteSigned`** - Microsoft's recommended setting for developers:
scripts you create or install locally (like `npm.ps1`) run; scripts downloaded from the internet must be signed.
It is set for your user (`CurrentUser`) and, when you update the System variables, for the machine (`LocalMachine`).

- It is shown in the preview, saved in the backup, and put back by **Undo**.
- If your organization forces a policy with Group Policy, Enviro Easy tells you and does **not** try to override it.
- Don't want it touched? Use `-SkipPolicy`.
- It also creates the `%APPDATA%\npm` folder when it is missing (a classic cause of `ENOENT ... AppData\Roaming\npm`) and adds it to your PATH.

## What it detects

| Tool | Added to PATH | Also |
|---|---|---|
| **Node.js** | folder with `node.exe` / `npm` / `npx` | `%APPDATA%\npm` (global npm packages; created if missing), fixes the PowerShell policy |
| **Python** | install folder + `Scripts` (`pip`) | `pip install --user` Scripts folders |
| **Git** | `cmd` folder | |
| **Java JDK** | `bin` | sets `JAVA_HOME` if missing or broken |
| **Android SDK** | `platform-tools` (`adb`), `cmdline-tools\...\bin` (`sdkmanager`), `emulator` | sets `ANDROID_HOME` if missing or broken |
| **Flutter** | `bin` | |
| **Dart** | `bin` (standalone SDK; Flutter already bundles Dart) | |
| **Maven** | `bin` | |
| **Gradle** | `bin` | |

Tool folders are added to **both** the System and the User `PATH`. Per-user folders (the npm global folder,
`pip --user` Scripts) go only into the User `PATH`, because they only exist for your account.

## How it finds them

You choose how hard to look (menu, or `-Search`):

| Mode | What it does | Speed |
|---|---|---|
| **Common** (default) | Already on PATH -> environment variables (`JAVA_HOME`, `ANDROID_HOME`, `FLUTTER_ROOT`, ...) -> Windows registry install records + the Python `py` launcher -> well-known folders on **every** drive | seconds |
| **`-Search C`** | All of the above **plus a deep search of the whole C: drive** | minutes |
| **`-Search All`** | All of the above **plus a deep search of every fixed drive** | slowest |

If the quick search can't find something, the menu offers to search C: for just those tools.

The deep search looks for each tool's signature file (`node.exe`, `javac.exe`, `adb.exe`, ...) and skips places that
only produce false hits: `node_modules`, `.git`, caches, `Windows`, the Recycle Bin, Python virtual environments, the
Store `python.exe` stub, and tools bundled inside other programs (IDE-private JDKs are ranked last).

If several versions are found you are asked which to use (newest is the default; **A** adds all, **S** skips). Use
`-AllVersions` to add every version without asking.

**Pick your tools:** choose **P** in the menu (or `-Pick`, or `-Tool Java,Android`) to look only for what you actually use.

## Options

Run `Setup-Development-Environment.bat` with options, or call the script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\EnviroEasy.ps1 [options]
```

| Option | What it does |
|---|---|
| *(none)* | Shows the menu. |
| `-DryRun` | Show what would change; change nothing. No administrator needed. |
| `-Scope Both` / `User` / `Machine` | Which variables to change: **System + User** (default), only your **User** variables (no administrator), or only **System**. |
| `-Tool Java,Android` | Only handle these tools: `Node`, `Python`, `Git`, `Java`, `Android`, `Flutter`, `Dart`, `Maven`, `Gradle` (aliases `npm`, `pip`, `jdk`, `sdk` work too). |
| `-Pick` | Ask which tools you have installed. |
| `-Search Common` / `C` / `All` | How hard to look (see above). |
| `-AllVersions` | Add every version found, not just the newest. |
| `-Force` | Overwrite `JAVA_HOME` / `ANDROID_HOME` even if they already point somewhere valid. |
| `-SkipPolicy` | Don't touch the PowerShell execution policy. |
| `-Yes` | Never ask questions; accept the defaults. |
| `-Restore` | Undo the last run (add `-BackupFile <path>` to pick a specific backup). |

Examples:

```
Setup-Development-Environment.bat -Search C -Yes
Setup-Development-Environment.bat -Tool Java,Android -Scope User
Preview-Changes.bat -Search All
```

## Safety

- **Preview first** with `-DryRun` / `Preview-Changes.bat`, and you are asked to confirm before anything is applied.
- **Additive only** - existing entries are never removed, reordered, or rewritten.
  `%VARIABLE%` entries stay exactly as you had them (a common bug in PATH scripts is
  expanding them and silently breaking things).
- **No duplicates** - compared ignoring case and trailing slashes, separately for the System and User PATH.
- **Automatic backup** before every change (one per scope) in `%LOCALAPPDATA%\EnviroEasy\backups`, including the
  previous execution policy. **Undo** puts everything back exactly - and itself saves a backup, so even an undo can be undone.
- **Nothing is downloaded or installed**, and nothing runs in the background. It only reads your system and edits
  environment variables (plus the execution policy, if you let it).
- It is one readable script. Please read [`EnviroEasy.ps1`](EnviroEasy.ps1) before running software that changes your system - you should do that for every tool like this one.

## Troubleshooting

**It worked but `node`/`python` still isn't found.**
Already-open terminals keep their old PATH. Close them (and VS Code / Android Studio) and open new ones.

**`npm` still says "running scripts is disabled".**
Run Enviro Easy again without `-SkipPolicy`. If it says the policy is forced by your organization, only your IT admin can change it - use Command Prompt (`cmd`) for npm.

**`python` opens the Microsoft Store.**
Windows ships a Store "stub" named `python.exe`. Enviro Easy puts the real Python *before* it, but you can also
turn the stub off: **Settings -> Apps -> Advanced app settings -> App execution aliases** -> switch off *python.exe* and *python3.exe*.

**A tool shows `[MISS] not found` but it is installed.**
Run it again and choose **Search my whole C: drive** (or **entire computer** if it is on another drive).

**The administrator prompt doesn't appear / I clicked No.**
Enviro Easy then continues with your **User** variables only and tells you so. Run it again and click **Yes** to update the System variables too.

**The deep search takes a long time.**
Searching a whole drive can take a few minutes on large disks. Use the default fast search first, or `-Tool` to
limit which tools you look for.

## Requirements

Windows 10 / 11 with Windows PowerShell 5.1 (built in). Tested on Windows 11. PowerShell 7 is not yet tested.

## Development

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

The tests run against throw-away registry keys, fake install folders and a fake execution policy - your real PATH,
variables and policy are never touched. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a tool.

## Roadmap

- `-Clean` to remove PATH entries that point to folders that no longer exist
- Rust, Go, .NET SDK, CMake, Docker CLI, Visual Studio Build Tools
- A tiny GUI
- PowerShell 7 and `winget` / Scoop awareness

## License

[MIT](LICENSE)
