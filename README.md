# gstack-no-telemetry

**gstack is the best skills framework for AI coding agents.** It makes Claude Code, Codex, and Gemini dramatically more capable. The QA testing, code review, shipping workflows, design audits... genuinely great software.

It also phones home.

Every skill invocation logs to local JSONL files. An opt-in prompt pushes for "community" or "anonymous" telemetry via a remote binary. Session IDs, skill names, durations, outcomes, timestamps... all tracked. Even if you say "no thanks," the local analytics directory still gets written to on every single skill run.

**Privacy is not a feature request. It's a requirement.**

This script removes all telemetry from gstack. Cleanly, completely, and automatically after every update.

---

## What gets removed

| Component | What it does | Gone |
|-----------|-------------|------|
| `_TEL`, `_TEL_START`, `_SESSION_ID` | Shell vars that track your session | Yes |
| `generateTelemetryPrompt()` | The opt-in prompt (community/anonymous/off) | Yes |
| `TEL_PROMPTED` flag | Tracks whether you've been asked about telemetry | Yes |
| `~/.gstack/analytics/` writes | Local JSONL logging on every skill run | Yes |
| `.pending-*` file handling | Deferred telemetry finalization | Yes |
| "Telemetry (run last)" epilogue | End-of-skill duration + outcome logging | Yes |
| `gstack-telemetry-log` | Remote telemetry binary | Deleted |
| `gstack-telemetry-sync` | Remote telemetry sync binary | Deleted |
| `gstack-analytics` | Analytics CLI binary | Deleted |
| Telemetry test assertions | Tests that would fail after stripping | Removed |

After patching, the script regenerates all 30+ `SKILL.md` files and verifies zero telemetry references remain.

**What stays:** Everything that makes gstack useful. Update checks, session tracking, skill discovery, repo mode detection, proactive suggestions, the browse daemon, all skill workflows. Nothing functional is touched.

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

Add this to your `~/.claude/CLAUDE.md`:

```markdown
## gstack Post-Upgrade

After any gstack upgrade completes (after `./setup` finishes), run `~/.gstack/strip-telemetry.sh` to remove telemetry. This is non-negotiable -- always run it.
```

Claude will strip telemetry automatically after every `/gstack-upgrade`. You never think about it again.

---

## How it works

The script is **idempotent**. Run it once, run it ten times. If telemetry is already gone, it exits in under a second.

Five phases:

1. **Patch the generator** -- Edits `scripts/resolvers/preamble.ts` to remove telemetry variables, the opt-in prompt function, the telemetry epilogue, and analytics writes. Fixes the proactive prompt dependency chain that was gated on telemetry state.

2. **Delete binaries** -- Removes the three telemetry executables from `bin/`.

3. **Patch tests** -- Strips telemetry-specific test cases so the suite stays green.

4. **Regenerate** -- Runs `bun run gen:skill-docs` to rebuild all skill files from the patched source.

5. **Verify** -- Greps every generated `SKILL.md` and the source for telemetry references. Fails loudly if anything slipped through.

### Requirements

- `bash`, `sed`, `python3` (standard on macOS and Linux)
- `bun` (already required by gstack)

---

## Why not just set telemetry to "off"?

Because `gstack-config set telemetry off` only disables the **remote** binary. The local analytics directory still gets created. The JSONL file still gets appended to on every skill run. The session ID is still generated. The duration timer still runs. The pending-file mechanism still executes.

"Off" means "we still collect it, we just don't send it." This script means "there is nothing to collect."

---

## FAQ

**Does this break gstack?**
No. Every functional feature works exactly the same. The script only removes code paths that exist solely for telemetry. Tests pass (214/215, the one pre-existing failure is unrelated to telemetry).

**Will gstack updates re-add telemetry?**
Yes, every time. That's why the CLAUDE.md instruction exists. Claude runs the script automatically after each upgrade.

**Does this work with vendored/local installs?**
Yes. Pass the install path as an argument: `~/.gstack/strip-telemetry.sh ./path/to/gstack`

**I use Codex/Kiro, not Claude Code.**
The script patches the source generator, so regenerated Codex/Kiro skill docs will also be telemetry-free. You may need to re-run `./setup` after stripping.

---

## License

MIT

---

*gstack is built by [Garry Tan](https://github.com/garrytan/gstack). This project is not affiliated with or endorsed by gstack. We just think great tools deserve great privacy defaults.*
