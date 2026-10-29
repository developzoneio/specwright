# sd-demo-loop

Demo re-plan protocol used by the contract-lint fixtures. `/sd:alpha` follows it.

## Gate Re-plan (HARD)

1. STOP. Present the discovery and the proposed delta. Ask:

<!-- SEEDED: protocol-details-undeclared - the shared protocol block offers details, but the manifest does not declare this file -->
   > Re-plan it? (approve / revise <feedback> / details <target> / abort task)

   - `approve` -> proceed. `revise` -> adjust and re-ask. `abort task` -> normal task abort.
