# ADR 0004 — Restricted visual plugins and isolated native extensions

Status: Accepted  
Baseline: v0.1

## Decision

Visual plugins should primarily use QML and restricted/versioned PSD APIs.

Third-party native code should preferably run outside the main shell process and communicate through IPC.

## Rationale

PSD wants extensibility without allowing one unstable native plugin to routinely crash the shell.

## Consequences

The project needs:

- manifests;
- capability permissions;
- explicit extension points;
- API versioning;
- configuration schemas;
- failure detection;
- Safe Mode support.
