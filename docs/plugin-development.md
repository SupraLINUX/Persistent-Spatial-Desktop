# Plugin Development v0.1

Status: **initial extension model**.

PSD is designed to be extensible without requiring a fork of the shell.

## Preferred plugin model

Visual plugins:

- QML;
- restricted PSD APIs;
- explicit extension points;
- capability-based permissions.

Third-party native code:

- preferably out of process;
- communicates over IPC;
- must not be the default way to extend the shell.

## Manifest

A plugin manifest should declare at minimum:

- stable plugin ID;
- name/version;
- PSD API version;
- plugin type;
- entry point;
- permissions/capabilities;
- configuration schema;
- compatibility constraints.

Machine-readable format is defined by `spec/plugins.schema.json`.

## Extension categories

Initial conceptual categories:

- surface widget;
- wallpaper provider;
- desktop provider;
- search provider;
- launcher provider;
- control provider;
- notification provider;
- AI provider;
- automation provider.

The list may evolve as implementation validates real extension needs.

## Failure isolation

A plugin should not be able to crash the whole shell when isolation is practical.

Repeated failures should be detectable and may cause automatic disable/quarantine.

Safe Mode always disables third-party plugins.
