# Changelog

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
