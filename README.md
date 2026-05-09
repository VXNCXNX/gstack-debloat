# gstack-no-telemetry

**gstack is the best skills framework for AI coding agents.** It makes Claude Code, Codex, and Gemini dramatically more capable. The QA testing, code review, shipping workflows, design audits... genuinely great software.

It also persists more than most people realize, and it ends every `/office-hours` run with a YC apply pitch and a curated funnel of YC/Lightcone/Paul Graham resources.

Remote telemetry is only one layer. gstack also writes local analytics, session timelines, and project learnings to `~/.gstack/`. That means skill names, timestamps, outcomes, durations, and AI-generated "learnings" can still accumulate on disk even when telemetry is set to `off`.

**Privacy is not a feature request. It's a requirement. And neither is the YC apply funnel.**

This script removes telemetry, the separate timeline/learnings persistence layer, and the `/office-hours` self-promotion block from gstack. Cleanly, completely, and automatically after every update.

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
| Telemetry test assertions | Tests that would fail after stripping | Removed |
| `/office-hours` "Garry's Personal Plea" | YC apply pitch (3 sub-tiers) + `ycombinator.com/apply?ref=gstack` | Removed |
| `/office-hours` "Founder Resources (all tiers)" | 34-item curated YC / Lightcone / Paul Graham funnel + open-in-browser flow | Removed |
| `/office-hours` `Then proceed to Founder Resources below.` stitches | Cross-tier handoff lines into the resource funnel | Removed |

After patching, the script regenerates all 30+ `SKILL.md` files and verifies that telemetry, timeline, learnings, and office-hours self-promo references are gone from generated skills.

**What stays:** Everything that makes gstack useful. Update checks, skill discovery, repo mode detection, proactive suggestions, the browse daemon, review logs, and the core skill workflows. Nothing user-facing is removed except persisted memory features.

---

## Install

One command. Lives in `~/.gstack/` so it survives gstack updates.

```bash
curl -fsSL https://raw.githubusercontent.com/VXNCXNX/gstack-no-telemetry/main/strip-telemetry.sh \
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
Download https://raw.githubusercontent.com/VXNCXNX/gstack-no-telemetry/main/strip-telemetry.sh to ~/.gstack/strip-telemetry.sh, make it executable, and run it. Then add a "gstack Post-Upgrade" section to my ~/.claude/CLAUDE.md that tells you to always run ~/.gstack/strip-telemetry.sh after any gstack upgrade.
```

That's it. Claude handles the install, runs the strip, and wires itself up to do it again after every future upgrade.

---

## How it works

The script is **idempotent**. Run it once, run it ten times. If telemetry is already gone, it exits in under a second.

Six phases:

1. **Patch the generator** -- Edits `scripts/resolvers/preamble.ts` to remove telemetry variables, timeline startup logging, learnings injection, and timeline-based context recovery. Fixes the proactive prompt dependency chain that was gated on telemetry state.

2. **Patch custom sources** -- Removes the custom learnings write-paths that live outside the generic resolver flow, including review and investigate templates.

3. **Neutralize binaries** -- Replaces telemetry, timeline, and learnings binaries in `bin/` with no-op stubs so even stale generated docs cannot write persisted state.

4. **Patch tests** -- Strips telemetry-specific test cases so the suite stays green.

5. **Strip office-hours self-promo** -- Patches `office-hours/SKILL.md.tmpl` (and the regenerated `SKILL.md`, plus `.agents/` and `~/.codex/` copies) to remove the YC apply pitch and the curated "Founder Resources" funnel from Phase 6 of the closing sequence. The skill still produces the design doc and recommends the next planning skill -- it just stops pitching YC.

6. **Regenerate and verify** -- Rebuilds all skill files from the patched source, then greps for telemetry/timeline/learnings references and `ycombinator.com/apply?ref=gstack` residue, failing loudly if anything slipped through.

### Requirements

- `bash`, `sed`, `python3` (standard on macOS and Linux)
- `bun` (already required by gstack)

---

## Why not just set telemetry to "off"?

Because `gstack-config set telemetry off` only disables the **remote** binary. The local analytics directory still gets created. The JSONL file still gets appended to on every skill run. Separate session timeline and learnings files can still be written under `~/.gstack/projects/`.

"Off" means "we still collect it locally, we just don't send it remotely." This script means "there is nothing left to collect."

---

## FAQ

**Does this break gstack?**
No. Core gstack workflows still work. The script removes telemetry and persisted local memory features. The main behavioral change is that timeline/history/learnings-based context recovery no longer exists, by design.

**Will gstack updates re-add this stuff?**
Yes. Upstream updates can reintroduce telemetry, timeline logging, and learnings persistence. That is why the CLAUDE.md instruction exists.

**Does this work with vendored/local installs?**
Yes. Pass the install path as an argument: `~/.gstack/strip-telemetry.sh ./path/to/gstack`

**I use Codex/Kiro, not Claude Code.**
The script patches the source generator, so regenerated Codex/Kiro skill docs will also be telemetry-free. You may need to re-run `./setup` after stripping.

---

## License

MIT

---

*gstack is built by [Garry Tan](https://github.com/garrytan/gstack). This project is not affiliated with or endorsed by gstack. We just think great tools deserve great privacy defaults.*
