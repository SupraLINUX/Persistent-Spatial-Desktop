# ADR 0003 — Hyprland as initial compositor base

Status: Accepted for initial implementation  
Baseline: v0.1

## Decision

Use Hyprland as the initial compositor base on Ubuntu 26.04.

A PSD spatial bridge/plugin may be required for coherent workspace/surface translation and compositor state integration.

## Constraints

- do not move individual app windows one by one if a lower-level compositor transform can provide the required behavior;
- keep shell/compositor interfaces explicit;
- do not treat Hyprland as irreversible.

## Revisit condition

Reconsider the compositor only when implementation produces a demonstrated blocker in compatibility, architecture, performance or required spatial behavior.
