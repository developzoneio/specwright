---
id: BUG-TEST-300
type: bug
status: in-progress
created: 2026-10-29
linked_specs: []
---

# Fixture spec

## Reproduction

1. Run the count with 3 todos.
2. Observe 2.

## Root cause

Root cause: the loop stops one short in src/count.js.
