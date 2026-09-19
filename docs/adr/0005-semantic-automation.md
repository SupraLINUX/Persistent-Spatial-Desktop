# ADR 0005 — Semantic automation with optional visual choreography

Status: Accepted  
Baseline: v0.1

## Decision

Meaningful PSD actions should be semantically addressable.

Automation executes through semantic APIs whenever possible. Visual mode may represent those actions through surface movement, highlights and an optional ghost cursor without making visual simulation the source of truth.

## Principles

- Everything meaningful should be addressable semantically.
- Semantic execution, optional visual choreography.
- Human input always has priority.

## Consequences

The same semantic infrastructure should support AI, accessibility, testing, scripts and plugins.
