# PSD machine-readable specifications

This directory is the canonical machine-readable surface for public PSD contracts.

Current files are **v0.1 bootstrap contracts**, not evidence of implemented runtime functionality.

## Categories

- `design-tokens.json` — Spatial Glass visual tokens.
- `capabilities.json` — top-level conceptual capabilities.
- `shell.schema.json` — primary spatial shell structure.
- `settings.schema.json` — user settings shape.
- `plugins.schema.json` — plugin manifests.
- `components.schema.json` — PSD.UI component descriptions.
- `actions.schema.json` — semantic actions.
- `events.schema.json` — semantic events.
- `permissions.schema.json` — capability permissions.
- `shortcuts.schema.json` — shortcut bindings.
- `ipc.schema.json` — generic IPC envelope.
- `automation.schema.json` — Direct/Visual/Guided automation requests.

## Rules

1. Public contracts are versioned.
2. Human documentation and schemas must not intentionally disagree.
3. Implementation must not silently expand a public contract without updating its schema.
4. Breaking schema changes require an explicit versioning decision.
5. Machine-readable contracts describe supported interfaces; they should not be used to claim implementation that does not yet exist.
