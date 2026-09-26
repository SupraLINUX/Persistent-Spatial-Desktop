# IPC and Public Interface Direction v0.1

Status: **initial architecture contract**.

PSD exposes one semantic action/state layer through multiple transports. Transport-specific code must not duplicate business logic.

## Planned transports

- D-Bus;
- local IPC;
- CLI (`psdctl`);
- JSON-RPC where justified;
- generated SDK/tool bindings.

## D-Bus naming direction

Conceptual bus name:

`org.supralinux.PSD`

Potential object domains:

- `/org/supralinux/PSD/Desktop`
- `/org/supralinux/PSD/Windows`
- `/org/supralinux/PSD/Spatial`
- `/org/supralinux/PSD/Workspaces`
- `/org/supralinux/PSD/Apps`
- `/org/supralinux/PSD/Search`
- `/org/supralinux/PSD/Settings`
- `/org/supralinux/PSD/Notifications`
- `/org/supralinux/PSD/Automation`

These names are provisional until the first concrete API schema is implemented.

## API requirements

Public operations should have:

- stable semantic name;
- typed request;
- typed result;
- declared errors;
- required permissions;
- version;
- machine-readable documentation.

## Introspection

Clients must be able to discover capabilities/actions/events without scraping documentation.

## Versioning

Breaking changes require an explicit API-version strategy. Schemas under `spec/` are the canonical machine-readable contracts.
