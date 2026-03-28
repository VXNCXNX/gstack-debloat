# gstack-no-telemetry

Remove telemetry from [gstack](https://github.com/garrytan/gstack) after every install or upgrade.

gstack is a great skills framework for Claude Code. It also ships with telemetry that logs your usage to local JSONL files and sends data to a remote binary. This script strips all of that cleanly.

## What gets removed

- **Telemetry shell variables** -- `_TEL`, `_TEL_START`, `_SESSION_ID` from the preamble bash output
- **Opt-in prompt logic** -- `TEL_PROMPTED` echo lines and conditional blocks
- **`generateTelemetryPrompt()` function** -- the entire function and its call site in preamble composition
- **Telemetry epilogue** -- the "Telemetry (run last)" section in completion status
- **Analytics directory writes** -- `mkdir -p ~/.gstack/analytics` and JSONL append lines
- **Telemetry binaries** -- `gstack-telemetry-log`, `gstack-telemetry-sync`, `gstack-analytics` from `bin/`
- **Test assertions** -- telemetry-related test cases that would fail after stripping
- **Docstring references** -- cleans up comments that mention telemetry

After patching, the script regenerates all `SKILL.md` files and verifies no telemetry references remain.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/VXNCXNX/gstack-no-telemetry/main/strip-telemetry.sh \
  -o ~/.gstack/strip-telemetry.sh && chmod +x ~/.gstack/strip-telemetry.sh
```

The script lives in `~/.gstack/` so it survives gstack updates.

## Usage

### Run manually

```bash
~/.gstack/strip-telemetry.sh
```

The script auto-detects the default gstack location (`~/.claude/skills/gstack`). To specify a custom path:

```bash
~/.gstack/strip-telemetry.sh /path/to/your/gstack
```

### Run automatically after every gstack upgrade

Add this line to your `CLAUDE.md` (project-level or global `~/.claude/CLAUDE.md`):

```markdown
After running any gstack upgrade command, run `~/.gstack/strip-telemetry.sh`
```

This way Claude will strip telemetry automatically whenever gstack updates itself.

## How it works

The script is **idempotent** -- safe to run multiple times. If telemetry is already removed, it exits immediately.

It works in five phases:

1. **Patch `preamble.ts`** -- Multi-pass `sed` removes shell variable declarations, echo lines, and mkdir/JSONL writes. A Python pass handles the `generateTelemetryPrompt()` function removal, preamble composition cleanup, docstring edits, and the telemetry epilogue in completion status.

2. **Delete binaries** -- Removes `gstack-telemetry-log`, `gstack-telemetry-sync`, and `gstack-analytics` from `bin/`.

3. **Patch tests** -- Removes telemetry-specific test cases from `gen-skill-docs.test.ts` so the test suite stays green.

4. **Regenerate SKILL.md** -- Runs `bun run gen:skill-docs` to rebuild all skill documentation from the patched source.

5. **Verify** -- Greps all `SKILL.md` files and `preamble.ts` for telemetry references. Exits with an error if any remain.

### Requirements

- `bash`, `sed`, `python3` (macOS/Linux standard)
- `bun` (used by gstack for `gen:skill-docs`)

## License

MIT
