---
id: RCA-TEST-500
type: rca
severity: P1
status: in-progress
created: 2026-11-01
---

# Checkout timeouts

## Symptoms observed

Checkout requests time out after the deploy.

## Hypothesis tree

H1: connection pool exhausted after deploy - high.

## Root cause

The pool size was halved by the 2026-10-01 config change.
