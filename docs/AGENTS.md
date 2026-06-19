# Docs Guide

## Purpose

Durable architecture, setup, component, contract, and testing documentation.

## Ownership

- `architecture/`: high-level architecture and hardening notes.
- `components/`: focused component behavior docs.
- `contract/`: product/runtime contracts.
- `setup/`: host, VM, and provisioning setup documentation.
- `testing.md`: test runner architecture and contracts.

## Local Contracts

- Docs should describe current behavior, not historical debugging notes.
- Update docs when changing durable setup behavior, status semantics, test
  runner contracts, generated artifacts, or module ownership.
- Keep docs concise and operational.

## Work Guidance

- Prefer exact command examples where users need to run something.
- Avoid duplicating root AGENTS.md rules unless the docs subtree needs local
  specificity.

## Verification

Docs-only changes usually require no shell validation unless they change
documented commands or runner contracts. For runner-contract docs, run:

```bash
bash tests/run-ci-tests.sh
```

## Child DOX Index

No child AGENTS.md files under `docs/`.
