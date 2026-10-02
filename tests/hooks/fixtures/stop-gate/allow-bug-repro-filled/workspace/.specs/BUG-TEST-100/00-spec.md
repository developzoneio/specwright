---
id: BUG-TEST-100
type: bug
severity: P2
status: in-progress
created: 2026-09-27
linked_specs: []
---

# Checkout double-charges on retry

## Symptom

A card is charged twice when checkout retries.

## Reproduction

<!-- Deterministic steps. Gate 2 requires <<this section>> to be confirmed. -->

1. POST /checkout with cart 42 and a card that times out once.
2. Let the client retry.

**Reproduction rate**: 100%

## Root cause

<!-- DO NOT FILL until Phase 3. -->

Retry reuses the idempotency key after it was cleared, so the charge runs twice.
