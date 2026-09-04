# MasterDesk project guide

MasterDesk is a Windows-focused RustDesk fork for branded remote support. Its
main parts are the Rust core/protocol/service, the Flutter desktop UI, Windows
capture/input/clipboard integrations, and the self-hosted ID/relay deployment.

## Read first

1. Read [docs/current-state.md](docs/current-state.md) before touching the tree.
   It is the volatile handoff and names the exact unfinished task and candidate.
2. Then read only the document relevant to the work:
   - component or protocol changes: [docs/architecture.md](docs/architecture.md)
   - build, packaging, install or update: [docs/build-and-run.md](docs/build-and-run.md)
   - validation and evidence: [docs/testing.md](docs/testing.md)
   - Windows sessions/capture/headless display: [docs/rdp-display.md](docs/rdp-display.md)
   - VMware/RDP/Windows-MCP: [docs/lab-environment.md](docs/lab-environment.md)
   - settled technical policy: [docs/decisions.md](docs/decisions.md)

`CODEX_START_HERE.md`, `CODEX_HANDOFF.md`, `CODEX_NEXT_PLAN.md` and
`PROJECT_CONTEXT.md` are historical records. Do not read them in full or treat
their old beta/current-state statements as authoritative.

## Mandatory working rules

- Preserve the dirty worktree. Never reset, clean, discard, or overwrite
  unrelated user changes. Change only the files required by the active task.
- Start from current files and current evidence, not from Git history. Inspect
  history only when it answers a concrete question.
- Use the smallest valid diff. No unrelated refactors or formatting-only edits.
- Never store passwords, bearer tokens, private keys, or reusable verifiers in
  the repository, command logs, config files, or artifacts.
- A production mutation needs a fresh explicit user instruction, verified
  backup, exact image/config attribution, tested rollback, and real direct and
  relay canaries. Never infer production authority from a client task.
- A no-argument Windows package is always portable. It must not auto-install or
  auto-update. Updating an installed copy starts only from the GUI **Update**
  action. Never create a `*-install.exe` package.
- Every changed EXE gets the next positive beta and the exact filename/embedded
  identity described in [docs/build-and-run.md](docs/build-and-run.md). Never
  rename an older binary to create a new identity.
- Rust production code must avoid `unwrap()`/`expect()` except tests or poisoned
  lock handling. Do not create nested Tokio runtimes, call `block_on()` inside
  async code, hold locks across `.await`, or sleep a Tokio task with
  `std::thread::sleep()`.
- In `src/lang/*.rs`, do not edit `template.rs` for translation work. Fill only
  empty values, preserve placeholders/escapes, and leave brand/protocol tokens
  untranslated.

## MasterDesk GUI/RDP testing

- For VMware/RDP, UAC, Windows GUI, clipboard and drag-and-drop runtime tests,
  use the `$masterdesk-rdp-lab` skill.
- Drive tested mouse and keyboard input through the visible host `mstsc` window.
  Use VM10-B for active B-to-A input and keep VM10-A observation-only unless the
  scenario explicitly requires otherwise.
- When the skill can perform an expected lab action autonomously, do not ask the
  user to confirm UAC or supply the drag, click or keypress manually.
- Store host screenshots, input traces, VM observations and verification results
  under `artifacts/`. A plus cursor or size-only request is not a Drag&Drop PASS.
- Identify automated input as `host-driven RDP mouse/keyboard` evidence; never
  describe it as a manual physical action.

## Build and test discipline

Use: targeted checks -> cached incremental build -> applicable VM runtime ->
one final candidate. Do not run `cargo clean`, clear caches, rebuild Flutter for
a Rust-only edit, or run the full VM matrix without a diagnosed reason.

Before handing off a code change, run the narrow tests for the changed path,
the required runtime check from [docs/testing.md](docs/testing.md), PowerShell
syntax checks for edited scripts, and `git diff --check`. Keep verbose output in
`artifacts/` and report compact results and exact hashes.
