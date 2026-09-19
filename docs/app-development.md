# Native PSD Application Development v0.1

Status: **initial application model**.

## Compatibility first

Applications do not need PSD-specific integration to run on PSD.

A standard Wayland/XWayland Linux application remains a normal application window.

## Native by choice

Applications may opt into PSD integration for:

- Spatial Glass components;
- semantic actions/state;
- shell search;
- notifications;
- contextual navigation;
- advanced drag-and-drop;
- automation;
- accessibility;
- shell services.

## UI stack

Preferred native PSD UI stack:

- Qt 6;
- Qt Quick/QML;
- PSD.UI.

Complex applications may pair QML with C++ or another appropriate native backend.

## PSD.UI

Conceptual namespaces:

```
PSD.UI
├── Foundations
├── Controls
├── Surfaces
├── Navigation
└── Window
```

Apps should consume design tokens rather than duplicating literal visual constants.

## Semantic application API

A native application should be able to expose:

- semantic actions;
- semantic state;
- events.

Example conceptual APIs:

```
notes.list()
notes.create()
notes.open()
notes.update()
notes.search()
```

The goal is to make native apps operable by humans, accessibility technology, scripts, testing and AI through the same underlying semantics.

## Machine-readable development contract

Public PSD components, actions, permissions and tokens are described in `spec/` so a tool or AI can generate/adapt applications without relying on screenshots.
