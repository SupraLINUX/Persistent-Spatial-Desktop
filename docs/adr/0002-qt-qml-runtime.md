# ADR 0002 — Qt 6 / QML owned runtime

Status: Accepted as initial architecture  
Baseline: v0.1

## Decision

Build the PSD shell directly on Qt 6 + Qt Quick/QML with a PSD-owned runtime. Use C++ where deep Qt, Wayland or system integration requires it.

Quickshell is a reference, not a required dependency.

## Rationale

PSD requires long-term control over:

- lifecycle;
- APIs;
- plugins;
- IPC;
- performance;
- design system;
- native application toolkit;
- machine-readable contracts.

## Consequences

PSD must implement some infrastructure that a generic shell framework would otherwise provide, but avoids making the product architecture dependent on that framework.
