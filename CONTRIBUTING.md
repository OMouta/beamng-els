# Contributing

Thanks for your interest in contributing to ELS Controller! This document describes how to set up a development environment and test your changes.

## Link For Testing

Run this from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File tools/link-dev.ps1
```

That creates a junction here:

```text
%LOCALAPPDATA%/BeamNG/BeamNG.drive/current/mods/unpacked/els_controller
```

pointing to the `src/` folder in your repo.

BeamNG loads the mod from the unpacked folder, but the files stay in your dev repo.

## Build For Publishing

Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools/pack-release.ps1
```

The release zip is written to:

```text
dist/els_controller.zip
```
