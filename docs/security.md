# Security Model v0.1

Status: **initial baseline**.

PSD's automation and plugin model creates powerful local capabilities. Security boundaries must be explicit from the beginning.

## Principles

- least privilege;
- explicit capabilities;
- human control takes priority;
- third-party native code should not run in the main shell process by default;
- semantic APIs must be permission-aware;
- Safe Mode must provide a recovery path.

## Automation permissions

Initial permission namespaces may include:

- `desktop.read`
- `desktop.modify`
- `windows.read`
- `windows.control`
- `apps.launch`
- `files.read`
- `files.write`
- `files.delete`
- `clipboard.read`
- `clipboard.write`
- `settings.read`
- `settings.modify`
- `network.control`
- `power.control`

The final permission catalog is versioned under `spec/`.

Different consumers may have different grants:

- user-owned script;
- PSD-native app;
- plugin;
- local AI;
- remote/bridged agent;
- service.

## Sensitive actions

Destructive or security-sensitive operations should support contextual authorization rather than relying solely on a broad permanent grant.

Examples:

- deleting data;
- changing security settings;
- power operations;
- exposing clipboard contents;
- privileged system changes.

## Plugins

Visual QML plugins should operate through restricted PSD APIs.

Untrusted native extensions should preferably run out of process.

Repeated plugin failures should allow automatic quarantine/disable behavior.

## Visual automation safety

Ghost cursors/highlights are cosmetic and must not impersonate physical user input internally.

Physical user input can interrupt visual choreography.

## Audit

PSD may retain an audit trail for meaningful automated operations, for example:

```
21:14:07 agent -> apps.launch("firefox")
21:14:10 agent -> settings.set("audio.volume", 40)
```

Audit must avoid storing sensitive payload contents unnecessarily and be user-configurable.

## Safe Mode

Safe Mode disables third-party plugins, external overrides and other non-essential customization to provide a known recovery environment.
