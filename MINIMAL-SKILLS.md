# gstack minimal skill install — map + `--minimal` design

Goal: add a `--minimal` mode to `strip-telemetry.sh` that prunes gstack from 54
skills down to a curated working set, removing the rest from every install copy
(repo subdirs, `.agents/`, `.kiro/`, `.factory/`, `~/.codex/skills`, `~/.agents/skills`).
Each removed skill drops its `name:` + `description:` from the agent's context
(token win) and its files from disk.

Note on "what was deleted": the ~20 top-level `~/.claude/skills/<name>` dirs that
existed at session start are gone and Trash is empty, so exact deletions can't be
reconstructed. The reliable signal is the full 54-skill catalog vs the active set
below. The git repo restored all 54 on the v1.58.3.0 update, so a `--minimal`
prune (uncommitted deletions, reproducible like the telemetry strip) is the right
mechanism.

## Catalog: 54 skills

### KEEP — core working set (20, your session-start active set)
browse, qa, review, investigate, retro, canary, benchmark, codex, cso, spec,
office-hours, autoplan, plan-ceo-review, plan-eng-review, plan-design-review,
plan-tune, design-review, design-consultation, design-shotgun, design-html

### KEEP candidates — likely want (confirm)
- ship — ship workflow (merge base, tests, review, build). Usually core.
- gstack-upgrade — update gstack to latest.
- setup-browser-cookies — import real cookies for authed QA (Preuve has auth).
- qa-only — report-only QA variant.

### STRIP — high confidence (irrelevant for a web SaaS) — 7
- iOS suite (5): ios-clean, ios-fix, ios-qa, ios-sync, ios-design-review — Preuve has no iOS app.
- devex-review, plan-devex-review (2) — confirmed not useful for a founder-facing web app.

### STRIP — likely (niche / unused), confirm
- gbrain (2): setup-gbrain, sync-gbrain — only if you don't use gbrain.
- docs/output: make-pdf, document-generate, document-release, diagram, landing-report
- browser extras: pair-agent, scrape, skillify, connect-chrome, open-gstack-browser (connect-chrome and open-gstack-browser are the same launcher)
- deploy: land-and-deploy, setup-deploy
- session/safety: context-save, context-restore, freeze, unfreeze, careful, guard, health
- meta: benchmark-models, learn (legacy alias)

## `--minimal` design (proposed)

New flags on `strip-telemetry.sh`:
- `--minimal` — prune to the built-in `MINIMAL_KEEP` list (KEEP core + KEEP candidates), remove all others.
- `--keep "a,b,c"` — explicit keep-list, overrides the built-in.
- `--keep-file PATH` — keep-list from a file (one skill per line).
- `--list-skills` — print catalog with current keep/strip status (no changes).
- Composes with the telemetry strip by default; `--minimal` implies a strip pass too.

Mechanism (idempotent, re-run-safe):
1. `CATALOG` = repo subdirs of `$GSTACK_DIR` that have `SKILL.md` **or only its `.tmpl`
   source** (`claude/` is template-only; upstream renders it for `.agents`/Codex hosts).
2. `STRIP_SET` = `CATALOG` − keep-list.
3. For each name in `STRIP_SET`, remove its dir from every root:
   `$GSTACK_DIR/<name>`, `$GSTACK_DIR/.agents/skills/gstack-<name>` (bare `<name>`
   when the skill is itself named `gstack-*`, e.g. `gstack-upgrade`),
   `$GSTACK_DIR/.kiro/skills/...`, `$GSTACK_DIR/.factory/skills/...`,
   `~/.codex/skills/gstack-<name>`, `~/.agents/skills/gstack-<name>` (+ bare `<name>`).
4. Run AFTER `gen:skill-docs` regeneration (so generated copies are pruned too),
   or prune source subdirs first then regenerate. Update/regenerate `llms.txt`.
5. Keep `gstack` (main) + `_gstack-command` always.

Caveats:
- Pruned repo subdirs are uncommitted git deletions — a future `git reset/checkout`
  on gstack update restores them, so re-run `--minimal` after each update (same as
  the telemetry strip). Document this.
- `--keep` is the safety valve; never strip outside `CATALOG`.
