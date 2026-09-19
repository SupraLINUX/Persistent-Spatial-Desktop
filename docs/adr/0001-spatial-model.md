# ADR 0001 — Persistent spatial model

Status: Accepted  
Baseline: v0.1

## Decision

PSD uses a five-region spatial model:

```
                    TOP
                     |
LEFT ------------- CENTER ------------- RIGHT
                     |
                    DASH
```

CENTER is a conventional Linux desktop. The other four regions are persistent shell surfaces.

Spatial navigation reveals a region by rigid translation rather than opening an overlay or scaling/compressing CENTER.

## Consequences

- shell navigation has a stable spatial mental model;
- LEFT/RIGHT/TOP/DASH retain state;
- compositor integration must support coherent CENTER movement;
- apps remain normal windows and are not converted into PSD surfaces;
- no intermediate BOTTOM region exists.
