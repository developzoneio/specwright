# Plan - FEAT-BROKEN-019

## Approach

Extend the existing failure logger to include the status code, and strip the body before it is
written.

## Risks

- None beyond the usual log-volume concern.

Complexity: 2 tasks, 1 production layer (Infrastructure), 1 impact file, 0 open questions - under threshold.
