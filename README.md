# gstack-debloat

**gstack is the best skills framework for AI coding agents.** It makes Claude Code and Codex dramatically more capable. The QA testing, code review, shipping workflows, design audits... genuinely great software.

It also ships with a pile of stuff you didn't ask for: telemetry, an auto update-check that fires on **every** skill invocation, dead `gstack-config` reads in half the skills, and an `/office-hours` closing sequence that ends in a YC apply pitch plus a curated funnel of YC/Lightcone/Paul Graham resources with a "want me to open these in your browser?" prompt.

Remote telemetry is only one layer. gstack also writes local analytics, session timelines, and project learnings to `~/.gstack/`. Skill names, timestamps, outcomes, durations, and AI-generated "learnings" accumulate on disk even when telemetry is set to `off`. None of it is opt-in, and all of it costs you tokens and noise on every run.

**This script strips all of it.** Telemetry, the timeline/learnings persistence layer, the auto update-check, the dead telemetry reads, and the office-hours self-promotion, gone. Cleanly, completely, and automatically after every upgrade, across every install copy (Claude Code, `.agents`, `.kiro`, `.factory`, Codex). The only thing kept is the local builder profile, because that one's actually useful and never leaves your machine.

---

## What gets removed

| Component | What it does | Gone |
|-----------|-------------|------|
| `_TEL`, `_TEL_START`, `_SESSION_ID` | Shell vars that track your session | Yes |
| `generateTelemetryPrompt()` | The opt-in prompt (community/anonymous/off) | Yes |
| `TEL_PROMPTED` flag | Tracks whether you've been asked about telemetry | Yes |
| `~/.gstack/analytics/` writes | Local JSONL logging on every skill run | Yes |
| `~/.gstack/projects/*/timeline.jsonl` | Per-project session timeline | Yes |
| `~/.gstack/projects/*/learnings.jsonl` | Per-project AI-generated learnings | Yes |
| `.pending-*` file handling | Deferred telemetry finalization | Yes |
| "Telemetry (run last)" epilogue | End-of-skill duration + outcome logging | Yes |
| `gstack-telemetry-log` | Remote telemetry binary | Deleted |
| `gstack-telemetry-sync` | Remote telemetry sync binary | Deleted |
| `gstack-analytics` | Analytics CLI binary | Deleted |
| `gstack-timeline-log` / `gstack-timeline-read` | Timeline persistence/readback binaries | Neutralized |
| `gstack-learnings-log` / `gstack-learnings-search` | Learnings persistence/readback binaries | Neutralized |
| `{{LEARNINGS_SEARCH}}` / `{{LEARNINGS_LOG}}` | Generated skill-doc injections for learnings | Removed |
| `### Refresh learnings` sections | Hardcoded mid-skill learnings re-pull blocks in `investigate` / `qa` / `ship` templates (v1.43+) | Removed |
| Telemetry test assertions | Tests that would fail after stripping | Removed |
| `_UPD=$(gstack-update-check ...)` preamble check | Auto update-check that runs on **every** skill invocation (network call + echoed output = token waste) | Removed |
| Standalone `_TEL=$(... get telemetry)` reads | Dead telemetry reads in `codex` / `autoplan` / `review` / `plan-*-review` / `ship` steps (value never consumed; runs `gstack-config` on every invoke) | Removed |
| `/office-hours` "Garry's Personal Plea" | YC apply pitch (3 sub-tiers) + `ycombinator.com/apply?ref=gstack` | Removed |
| `/office-hours` "Founder Resources (all tiers)" | 34-item curated YC / Lightcone / Paul Graham funnel + open-in-browser flow | Removed |
| `/office-hours` `Then proceed to Founder Resources below.` stitches | Cross-tier handoff lines into the resource funnel | Removed |

After patching, the script regenerates all 50+ `SKILL.md` files and runs a final comprehensive sweep (Phase 4.8) over **every** rendered skill and section file across all install copies — main, `.agents/`, `.kiro/`, `.factory/`, and `~/.codex/` — then verifies that telemetry, timeline, learnings, auto update-check, dead `_TEL=` reads, and office-hours self-promo references are gone. The local builder profile (`gstack-developer-profile`) is intentionally kept.

**What stays:** Everything that makes gstack useful. Skill discovery, repo mode detection, proactive suggestions, the browse daemon, review logs, and the core skill workflows. The opt-in `/gstack-upgrade --force` check stays too, so you can still upgrade manually when you choose. Only the *automatic* per-preamble update-check is removed. Nothing user-facing is removed except persisted memory features and the auto update-check.

---

## Install

One command. Lives in `~/.gstack/` so it survives gstack updates.

```bash
curl -fsSL https://raw.githubusercontent.com/VXNCXNX/gstack-debloat/main/strip-telemetry.sh \
  -o ~/.gstack/strip-telemetry.sh && chmod +x ~/.gstack/strip-telemetry.sh
```

## Use

### Manual

```bash
~/.gstack/strip-telemetry.sh
```

Custom gstack location:

```bash
~/.gstack/strip-telemetry.sh /path/to/your/gstack
```

### Automatic (recommended)

Add this to your `~/.claude/CLAUDE.md` (or paste it into the Claude Code / Codex CLI as a prompt):

```
Download https://raw.githubusercontent.com/VXNCXNX/gstack-debloat/main/strip-telemetry.sh to ~/.gstack/strip-telemetry.sh, make it executable, and run it. Then add a "gstack Post-Upgrade" section to my ~/.claude/CLAUDE.md that tells you to always run ~/.gstack/strip-telemetry.sh after any gstack upgrade.
```

That's it. Claude handles the install, runs the strip, and wires itself up to do it again after every future upgrade.

---

## How it works

The script is **idempotent**. Run it once, run it ten times. If telemetry is already gone, it exits in under a second.

Seven phases:

1. **Patch the generator** -- Edits `scripts/resolvers/preamble.ts` (and the v1.6+ `generate-preamble-bash.ts` sub-module) to remove telemetry variables, timeline startup logging, learnings injection, timeline-based context recovery, and the per-preamble auto update-check. Fixes the proactive prompt dependency chain that was gated on telemetry state.

2. **Patch custom sources** -- Removes the custom learnings write-paths that live outside the generic resolver flow, including the `review` template and the hardcoded `### Refresh learnings` re-pull sections in the `investigate`, `qa`, and `ship` templates (added in gstack v1.43).

3. **Neutralize binaries** -- Replaces telemetry, timeline, and learnings binaries in `bin/` with no-op stubs so even stale generated docs cannot write persisted state.

4. **Patch tests** -- Strips telemetry-specific test cases so the suite stays green.

5. **Strip office-hours self-promo** -- Patches `office-hours/SKILL.md.tmpl` and the Phase 6 section file `office-hours/sections/design-and-handoff.md.tmpl` (which v1.57+ Reads at runtime instead of inlining), plus the regenerated `.md` renders and the `.agents/` / `~/.codex/` copies. Removes the YC apply pitch, the curated "Founder Resources" funnel, and the "Want me to open these in your browser?" prompt from Phase 6 of the closing sequence. The skill still produces the design doc and recommends the next planning skill -- it just stops pitching YC.

6. **Comprehensive sweep (Phase 4.8)** -- Walks every rendered `SKILL.md` and `sections/*.md` across **all** install copies (main, `.agents/`, `.kiro/`, `.factory/`, `~/.codex/`) and strips anything the targeted phases miss: standalone dead `_TEL=$(... get telemetry)` reads, orphaned stubbed-binary call lines, whole `### Refresh learnings` mini-sections, and the empty ```bash``` fences left behind. Guarded so it never leaves a dangling `$_TEL` reference, and the local builder profile is left intact.

7. **Verify** -- Greps every copy for telemetry/timeline/learnings references, residual `_UPD=` and `_TEL=` lines, and `ycombinator.com/apply?ref=gstack` residue, failing loudly if anything slipped through.

### Requirements

- `bash`, `sed`, `python3` (standard on macOS and Linux)
- `bun` (already required by gstack)

### Compatibility

Tested through gstack **v1.57.10.0**. The script is version-tolerant: each phase
matches its patterns idempotently and skips cleanly when a pattern is absent, so
it keeps working across gstack releases. New persistence surfaces introduced
upstream are added phase by phase as they appear.

---

## Why not just set telemetry to "off"?

Because `gstack-config set telemetry off` only disables the **remote** binary. The local analytics directory still gets created. The JSONL file still gets appended to on every skill run. Separate session timeline and learnings files can still be written under `~/.gstack/projects/`.

"Off" means "we still collect it locally, we just don't send it remotely." This script means "there is nothing left to collect."

---

## FAQ

**Does this break gstack?**
No. Core gstack workflows still work. The script removes telemetry and persisted local memory features. The main behavioral change is that timeline/history/learnings-based context recovery no longer exists, by design.

**Will gstack updates re-add this stuff?**
Yes. Upstream updates can reintroduce telemetry, timeline logging, learnings persistence, and the auto update-check. That is why the CLAUDE.md instruction exists.

**Does this work with vendored/local installs?**
Yes. Pass the install path as an argument: `~/.gstack/strip-telemetry.sh ./path/to/gstack`

**I use Codex/Kiro, not Claude Code.**
The script patches the source generator, so regenerated Codex/Kiro skill docs will also be telemetry-free. You may need to re-run `./setup` after stripping.

---

## License

MIT

---

*gstack is built by [Garry Tan](https://github.com/garrytan/gstack). This project is not affiliated with or endorsed by gstack. We just think great tools deserve great privacy defaults.*
