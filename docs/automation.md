# Automation, APIs and AI Integration v0.1

Status: **baseline direction closed**.

## Principles

> Everything meaningful should be addressable semantically.

> Semantic execution, optional visual choreography.

PSD should expose meaningful desktop and application operations through semantic APIs. Mouse/keyboard simulation and computer vision remain available, but they are fallback mechanisms when a better semantic interface exists.

The same infrastructure should support:

- AI agents;
- accessibility;
- scripts;
- plugins;
- automated testing;
- administration.

## Automation modes

### Direct

Execute semantic actions immediately with minimal visual choreography.

### Visual

Execute the real action semantically while the shell visually represents what is happening.

Example:

`apps.launch("firefox")` may be represented by revealing LEFT, focusing search, highlighting Firefox, launching it, and returning to CENTER.

The choreography is not the cause of the action.

### Guided

Like Visual, but may pause for user authorization or choices.

A future demonstration mode may include a clearly distinct ghost cursor and instructional highlights.

## Human priority

Physical user input always has priority.

Mouse, keyboard, touchpad or an explicit cancel action may interrupt choreography when appropriate.

Automation must not lock the user out to finish an animation.

## Semantic domains

Initial conceptual domains include:

- desktop;
- windows;
- spatial;
- workspaces;
- apps;
- settings;
- search;
- notifications;
- media;
- files where a file provider/application exposes them.

Examples are illustrative until formalized in `spec/`.

## Introspection

Automation clients must be able to discover what PSD can do.

Required concepts:

- `capabilities.list()`;
- `actions.list()`;
- `actions.describe()`;
- application-specific capability discovery;
- typed arguments/results;
- permissions;
- versioning;
- documented errors.

## Events

Prefer event subscriptions over polling.

Expected event families include:

- window opened/closed/focus changed;
- workspace changed;
- spatial state changed;
- notification received;
- network state changed;
- battery state;
- media track/player changes;
- plugin failure.

## Transport model

Business logic must not be duplicated per transport.

One internal semantic action layer may be exposed through:

- D-Bus;
- local IPC;
- CLI;
- JSON-RPC where useful;
- SDKs;
- MCP/tools.

Planned CLI: `psdctl`.

## External applications

Preferred control order:

1. application-native semantic API;
2. PSD API;
3. D-Bus or another standard protocol;
4. accessibility/AT-SPI;
5. compositor/window metadata;
6. vision plus mouse/keyboard.

## Native PSD applications

A native PSD app should be able to expose:

1. human UI;
2. semantic actions;
3. semantic state;
4. events.

This should allow automation without locating visual controls by coordinates.

## Visual choreography

Visual mode may use:

- surface reveals;
- highlights;
- temporary labels;
- animated control state;
- optional ghost cursor.

Visual choreography must never falsify success. The semantic operation result remains authoritative.

## Permissions and audit

Automation uses explicit capabilities and permissions. Sensitive actions may require user authorization.

Important automated actions may be auditable without unnecessarily logging sensitive content.

Detailed permission rules are defined in `docs/security.md` and machine-readable schemas under `spec/`.
