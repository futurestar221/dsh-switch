# Architecture

## Overview

```text
Start.cmd
  ├─ app/dsh-switch.exe        native WinForms + WebView2 shell
  └─ web/start.ps1             browser mode fallback
        └─ web/watchdog.ps1
              └─ web/server.ps1  HttpListener on 127.0.0.1

web/ui.html  <──── /api/* ────  web/server.ps1
                                     │
                                     └─ lib/core.ps1
```

## Components

### `src/native/Program.cs`

Small WinForms shell. It:

- enforces a single application instance;
- finds the repository root from `DSH_SWITCH_ROOT`, the executable parent or its own directory;
- launches `web/start.ps1` if the backend is not already alive;
- opens the local UI in WebView2;
- asks the backend to quit when the window closes.

It does not implement environment logic.

### `web/server.ps1`

Local HTTP server and API router. Responsibilities:

- bind to a random port on `127.0.0.1`;
- serve the UI and static assets;
- expose environment, profile, migration, shortcut and trash operations;
- enforce same-origin / `X-Dshm` checks for `/api/*`;
- write the live port to `%APPDATA%\dsh-manager\web.port`.

### `lib/core.ps1`

Business logic shared by the server and tools:

- locate DeepSeek Harness;
- load and atomically save the instance table;
- detect and control DSH processes;
- inspect plugin and skill counts;
- create/switch/remove profiles;
- copy, validate and migrate environments;
- move deleted environments to the application trash and restore them.

### `web/ui.html`

Single-page local UI. It has no framework or CDN dependency and calls only `/api/*` on the same local origin.

### `web/watchdog.ps1`

Keeps the backend available if it exits unexpectedly.

## Data model

Manager data is stored under `%APPDATA%\dsh-manager` (the directory name is kept for backward compatibility):

```text
config.json      DSH executable and default instance root
instances.json   environment list
current.json     process marker / selected environment
web.port         active local HTTP port
dsh-manager.log  operation log
trash/           deleted environments awaiting restore
```

An environment record contains:

```json
{
  "name": "Work",
  "home": "D:\\DSH\\work\\home",
  "agents": "D:\\DSH\\work\\agents"
}
```

`home` is the environment-specific DSH data directory. `agents` is an optional skill directory.

## Environment switching

DSH desktop has a single-instance lock, so switching means:

1. close the running DSH window;
2. wait for it to exit, then force-stop only if necessary;
3. set `DSH_HOME` and optional `DSH_AGENTS_HOME`;
4. start the configured `DeepSeek Harness.exe`;
5. write a marker for the active environment.

## Profiles

A profile is a plugin/startup combination inside one HOME. The desktop DSH version used by this project reads `<home>\profiles\desktop`, so switching a profile changes that junction target. Chat history and login data stay in the HOME.

## Migration and deletion

- Migration first copies data into a temporary destination, validates it, then moves it into place.
- Links that point inside the old HOME are rewritten to the new HOME.
- The source is retained by default; the user may explicitly retire it to the application trash.
- Deletion moves the directory into the application trash instead of deleting it immediately.

## Security boundary

The server is a local privileged helper for the current Windows user. It must never bind to a public interface. Browser API calls are accepted only when they are same-origin, carry `X-Dshm: 1`, or come from a non-browser client with no foreign Origin. The UI never loads remote content.

## Build

`scripts/build-app.ps1`:

1. locates the .NET Framework C# compiler;
2. restores the pinned WebView2 SDK from NuGet (or accepts `-WebView2Dir`);
3. compiles `src/native/Program.cs` as a 64-bit WinForms executable;
4. copies WebView2 runtime assemblies and the application config into `app/`.

`Start.cmd` prefers `app/dsh-switch.exe`; if it is absent, it falls back to the browser UI.

## Verification

`verify.ps1` checks required files, PowerShell syntax, version consistency, personal paths, secret patterns, assets, loopback-only binding and CSRF handling. `scripts/smoke-test.ps1` starts an isolated temporary backend and verifies the main endpoints.