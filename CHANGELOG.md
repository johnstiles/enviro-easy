# Changelog

## 1.1.0

- **System AND User variables.** New default `-Scope Both` updates the System and the User `PATH`
  (and `JAVA_HOME` / `ANDROID_HOME`). Asks for administrator permission with the normal Windows prompt;
  if declined, continues with the User variables only. `-Scope User` / `-Scope Machine` still available.
- **npm in Windows PowerShell.** Detects the `Restricted` / `AllSigned` execution policy that makes `npm.ps1`
  fail ("running scripts is disabled") and sets `RemoteSigned`. Saved in the backup and reverted by Undo.
  A policy forced by Group Policy is reported, never overridden. `-SkipPolicy` opts out.
- Creates the missing `%APPDATA%\npm` folder (fixes `ENOENT ... AppData\Roaming\npm`) and adds it to the User PATH.
- **Deep search** of the C: drive (`-Search C`) or every fixed drive (`-Search All`), with live progress.
  Skips `node_modules`, caches, system folders, Python virtual environments, the Store stub, and ranks
  IDE-bundled copies last.
- **Interactive menu** when run with no options; **tool picker** (`-Pick`) so you choose what you have installed;
  asks which install to use when several are found; offers a deeper search when something is not found.
- **Verification in a real Windows PowerShell** as well as Command Prompt. (v1.0 ran under `-ExecutionPolicy Bypass`,
  which hid the npm problem and would have reported npm as working.)
- Fixed: `-Tool Java,Android` failed when passed through the `.bat` / `-File`. Tool aliases `npm`, `pip`, `jdk`, `sdk` added.
- Duplicate detection is now per scope, so a folder already in the System PATH is still added to the User PATH.

## 1.0.0

First public release.

- Detects Node.js/npm, Python/pip, Git, Java JDK, Android SDK, Flutter, Dart, Maven and Gradle.
- Finds installs in non-default locations via PATH, environment variables, the registry,
  the Python `py` launcher and well-known folders on every fixed drive.
- Additive, duplicate-free PATH updates that preserve `%VARIABLE%` entries and the registry value type.
- Sets `JAVA_HOME` / `ANDROID_HOME` when missing or broken.
- Puts new folders before the Windows Store `python.exe` stub.
- `-DryRun`, `-Tool`, `-Scope`, `-AllVersions`, `-Force`.
- Automatic backups and `-Restore` (`Undo-Last-Change.bat`).
- Verifies each tool after applying, using the refreshed PATH.
- Broadcasts the change so Explorer-launched programs see it without a reboot.
- Test suite that runs against a sandbox registry key.
