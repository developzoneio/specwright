---
name: sd-keeper
color: blue
description: Demo agent used by the contract-lint fixtures.
model: haiku
<!-- SEEDED: write-capable-unused-tool - sd-keeper carries Write below but its body never mentions it -->
tools: Read, Grep, Write
skills:
  - sd-demo-rule
---

You are the demo agent. Follow the **sd-demo-rule** skill on every task.

## `TASK = draft`

Inputs (required): none
Inputs (optional): none

`Grep` for any existing draft first. Read `templates/sd/demo.template.md` and return
the drafted body. The main thread persists the result; you never touch disk yourself.
