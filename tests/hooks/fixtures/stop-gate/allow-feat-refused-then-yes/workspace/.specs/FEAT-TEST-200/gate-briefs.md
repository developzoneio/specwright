# Gate briefs - FEAT-TEST-200
Append-only. Each section is the text shown at that gate pass.

## Gate 1 - Spec approval (pass 1)

What changes: todos can be counted by status.
Decisions: none - the spec only restates the request.
Risk: none found.
Approve spec FEAT-TEST-200? (yes / refine <feedback> / details / abort)

### More decisions (shown on details)

- none

Reply: yes

## Gate 2 - Plan approval (pass 1)

What changes: one method and one test.
Decisions: none - the plan adds no choice beyond the approved spec.
Risk: none found.
Blocking: 1 criteria with no task - approval refused until 0.
Blocking: a count of zero for an empty list - no task covers it
| Task | What it does | Main file |
|---|---|---|
| T01 | Count todos by status | src/service.js |
| T02 | Test the count | tests/service.test.js |
Approve plan for FEAT-TEST-200? (2 tasks, complexity S, 1 criteria with no task) (yes / refine <feedback> / details <target> / abort)

Reply: refused - yes (1 criterion has no task)

Reply: refine add a task for the empty list

## Gate 2 - Plan approval (pass 2)

What changes: one method and one test.
Decisions: none - the plan adds no choice beyond the approved spec.
Risk: none found.
Criteria with no task: none
| Task | What it does | Main file |
|---|---|---|
| T01 | Count todos by status | src/service.js |
| T02 | Test the count | tests/service.test.js |
Approve plan for FEAT-TEST-200? (2 tasks, complexity S, 0 criteria with no task) (yes / refine <feedback> / details <target> / abort)

Reply: yes
