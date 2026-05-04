#!/usr/bin/env bash
# ============================================================================
# strip-telemetry.sh -- Remove telemetry and local session memory from gstack
#
# gstack (https://github.com/garrytan/gstack) ships with built-in telemetry and
# local session-intelligence persistence. This script strips both cleanly after
# every install or upgrade.
#
# Idempotent: safe to run multiple times. Exits gracefully if already clean.
# Compatible with gstack v0.x through v1.6+.
#
# Usage: ./strip-telemetry.sh [GSTACK_DIR]
#   GSTACK_DIR defaults to ~/.claude/skills/gstack
# ============================================================================
set -euo pipefail

GSTACK_DIR="${1:-$HOME/.claude/skills/gstack}"

if [ ! -f "$GSTACK_DIR/scripts/resolvers/preamble.ts" ] && \
   [ ! -f "$GSTACK_DIR/scripts/resolvers/preamble/generate-preamble-bash.ts" ]; then
  echo "strip-telemetry: no preamble found at $GSTACK_DIR -- skipping" >&2
  exit 0
fi

echo "strip-telemetry: patching $GSTACK_DIR ..."

# Write the full Python patcher to a temp file (avoids heredoc->python3 stdin
# forking issues on Windows/Cygwin Git Bash).
_TMP=$(mktemp /tmp/gstack_strip_XXXXXX.py 2>/dev/null || mktemp)
trap 'rm -f "$_TMP"' EXIT

cat > "$_TMP" << 'PYEOF'
#!/usr/bin/env python3
"""
gstack telemetry strip — all phases in one Python process.
Called by strip-telemetry.sh with GSTACK_DIR as argv[1].
"""
from pathlib import Path
import re, sys, shutil

GSTACK_DIR = Path(sys.argv[1])

# ─── helpers ──────────────────────────────────────────────────────────────────

def patch(path: Path, fn):
    """Read path, apply fn(content)->content, write back iff changed."""
    if not path.exists():
        return
    orig = path.read_text(encoding='utf-8')
    result = fn(orig)
    if result == orig:
        print(f"  {path.name} already clean", file=sys.stderr)
    else:
        path.write_text(result, encoding='utf-8')

def strip_skill_usage(path: Path) -> None:
    """Remove skill-usage.jsonl write blocks from any file."""
    if not path.exists():
        return
    c = path.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'mkdir -p ~/\.gstack/analytics\n'
        r"echo '\{\"skill\":\"[^\"]*\"[^\n]*skill-usage\.jsonl[^\n]*\n",
        '', c,
    )
    c = re.sub(r"echo '[^\n]*skill-usage\.jsonl[^\n]*\n", '', c)
    if c != orig:
        path.write_text(c, encoding='utf-8')

# ─── Phase 1a: legacy monolith preamble.ts (v0.x / v1.0-v1.5) ───────────────

def patch_preamble_monolith(c: str) -> str:
    # v1.5 comment form
    c = c.replace(
        " * The preamble provides: update checks, session tracking, user preferences,\n"
        " * repo mode detection, and telemetry.\n"
        " *\n"
        " * Telemetry data flow:\n"
        " *   1. Always: local JSONL append to ~/.gstack/analytics/ (inline, inspectable)\n"
        ' *   2. If _TEL != "off" AND binary exists: gstack-telemetry-log for remote reporting\n',
        " * The preamble provides: update checks, user preferences, and repo mode detection.\n",
    )
    c = c.replace(
        " * The preamble provides: update checks, session tracking, user preferences,\n"
        " * and repo mode detection.\n",
        " * The preamble provides: update checks, user preferences, and repo mode detection.\n",
    )
    # v1.6 comment form
    c = re.sub(
        r' \* tracking, user preferences, repo mode detection, model overlays, and\n'
        r' \* telemetry\.\n'
        r' \*\n'
        r' \* Telemetry data flow:\n'
        r' \*   1\. Always: local JSONL append to ~/\.gstack/analytics/ \(inline, inspectable\)\n'
        r' \*   2\. If _TEL != "off" AND binary exists: gstack-telemetry-log for remote reporting\n',
        ' * tracking, user preferences, and repo mode detection.\n',
        c,
    )
    c = re.sub(r'\nfunction generateTelemetryPrompt\(.*?\n\}\n', '\n', c, flags=re.DOTALL)
    c = re.sub(r'[ \t]*generateTelemetryPrompt\(ctx\),\n', '', c)
    c = re.sub(r'_TEL=\$\(.*?^done\n', '', c, flags=re.DOTALL | re.MULTILINE)
    c = re.sub(
        r'# Learnings count\n.*?^# Check if CLAUDE\.md has routing rules\n',
        '# Check if CLAUDE.md has routing rules\n',
        c, flags=re.DOTALL | re.MULTILINE,
    )
    c = c.replace(
        r"If \`PROACTIVE_PROMPTED\` is \`no\` AND \`TEL_PROMPTED\` is \`yes\`: After telemetry is handled,",
        r"If \`PROACTIVE_PROMPTED\` is \`no\` AND \`LAKE_INTRO\` is \`yes\`: After the lake intro is handled,",
    )
    c = re.sub(r'## Operational Self-Improvement.*?## Plan Mode Safe Operations', '## Plan Mode Safe Operations', c, flags=re.DOTALL)
    c = c.replace(
        '- \\`codex exec\\` / \\`codex review\\` (outside voice, plan review, adversarial challenge)\n'
        '- Writing to \\`~/.gstack/\\` (config, analytics, review logs, design artifacts, learnings)\n',
        '- \\`codex exec\\` / \\`codex review\\` (outside voice, plan review, adversarial challenge)\n'
        '- Writing to \\`~/.gstack/\\` (config, review logs, design artifacts)\n',
    )
    c = re.sub(r'  # Timeline summary \(last 5 events\)\n.*?  _LATEST_CP=', '  _LATEST_CP=', c, flags=re.DOTALL)
    c = c.replace(
        'If \\`LAST_SESSION\\` is shown, mention it briefly: "Last session on this branch ran\n'
        '/[skill] with [outcome]." If \\`LATEST_CHECKPOINT\\` exists, read it for full context\n'
        'on where work left off.\n\n'
        'If \\`RECENT_PATTERN\\` is shown, look at the skill sequence. If a pattern repeats\n'
        '(e.g., review,ship,review), suggest: "Based on your recent pattern, you probably\n'
        'want /[next skill]."\n\n'
        '**Welcome back message:** If any of LAST_SESSION, LATEST_CHECKPOINT, or RECENT ARTIFACTS\n'
        'are shown, synthesize a one-paragraph welcome briefing before proceeding:\n'
        '"Welcome back to {branch}. Last session: /{skill} ({outcome}). [Checkpoint summary if\n'
        'available]. [Health score if available]." Keep it to 2-3 sentences.',
        'If \\`LATEST_CHECKPOINT\\` exists, read it for full context on where work left off.\n\n'
        '**Welcome back message:** If any of LATEST_CHECKPOINT or RECENT ARTIFACTS\n'
        'are shown, synthesize a one-paragraph welcome briefing before proceeding:\n'
        '"Welcome back to {branch}. [Checkpoint summary if available]. [Health score if\n'
        'available]." Keep it to 2-3 sentences.',
    )
    c = c.replace('T1: core + upgrade + lake + telemetry + voice', 'T1: core + upgrade + lake + proactive + voice')
    return c

preamble_mono = GSTACK_DIR / 'scripts/resolvers/preamble.ts'
if preamble_mono.exists():
    patch(preamble_mono, patch_preamble_monolith)

# ─── Phase 1b: v1.6+ sub-modules ─────────────────────────────────────────────

preamble_bash = GSTACK_DIR / 'scripts/resolvers/preamble/generate-preamble-bash.ts'
if preamble_bash.exists():
    def _patch_bash(c):
        c = re.sub(
            r'_TEL=\$\([^)]*gstack-config get telemetry[^\n]*\)\n'
            r'_TEL_PROMPTED=\$\([^\n]*\)\n'
            r'_TEL_START=\$\([^\n]*\)\n'
            r'_SESSION_ID=[^\n]*\n'
            r'echo "[^\n]*TELEMETRY[^\n]*"\n'
            r'echo "[^\n]*TEL_PROMPTED[^\n]*"\n',
            '', c,
        )
        c = re.sub(
            r'mkdir -p ~/\.gstack/analytics\n'
            r'if \[ "\$_TEL" != "off" \]; then\n'
            r'echo[^\n]*skill-usage\.jsonl[^\n]*\n'
            r'fi\n',
            '', c,
        )
        c = re.sub(r'# zsh-compatible.*?^done\n', '', c, flags=re.DOTALL | re.MULTILINE)
        c = re.sub(r'# Learnings count\n.*?echo "LEARNINGS: 0"\nfi\n', '', c, flags=re.DOTALL)
        c = re.sub(r'# Session timeline: record skill start.*?2>/dev/null &\n', '', c, flags=re.DOTALL)
        return c
    patch(preamble_bash, _patch_bash)

tel_prompt = GSTACK_DIR / 'scripts/resolvers/preamble/generate-telemetry-prompt.ts'
if tel_prompt.exists():
    tel_prompt.write_text(
        "import type { TemplateContext } from '../types';\n\n"
        "export function generateTelemetryPrompt(_ctx: TemplateContext): string {\n"
        "  return '';\n"
        "}\n",
        encoding='utf-8',
    )

completion = GSTACK_DIR / 'scripts/resolvers/preamble/generate-completion-status.ts'
if completion.exists():
    def _patch_completion(c):
        c = re.sub(r'## Operational Self-Improvement\n.*?(?=## Plan Mode Safe Operations)', '', c, flags=re.DOTALL)
        c = re.sub(
            r"(writes to `~~/\.gstack/`[^\n]*)analytics,? ?([^\n]*\n)",
            lambda m: m.group(0).replace('analytics, ', '').replace(', analytics', ''),
            c,
        )
        return c
    patch(completion, _patch_completion)

ctx_recovery = GSTACK_DIR / 'scripts/resolvers/preamble/generate-context-recovery.ts'
if ctx_recovery.exists():
    def _patch_ctx(c):
        c = re.sub(r'  # Timeline summary \(last 5 events\)\n.*?  _LATEST_CP=', '  _LATEST_CP=', c, flags=re.DOTALL)
        c = re.sub(r"If `LAST_SESSION` is shown.*?want /\[next skill\]\.\"\n\n", '', c, flags=re.DOTALL)
        c = c.replace(
            '**Welcome back message:** If any of LAST_SESSION, LATEST_CHECKPOINT, or RECENT ARTIFACTS',
            '**Welcome back message:** If any of LATEST_CHECKPOINT or RECENT ARTIFACTS',
        )
        c = re.sub(
            r'"Welcome back to \{branch\}\. Last session: /\[skill\] \(\[outcome\]\)\. \[Checkpoint summary if\navailable\]\.',
            '"Welcome back to {branch}. [Checkpoint summary if available].',
            c,
        )
        return c
    patch(ctx_recovery, _patch_ctx)

proactive = GSTACK_DIR / 'scripts/resolvers/preamble/generate-proactive-prompt.ts'
if proactive.exists():
    def _patch_proactive(c):
        return c.replace(
            r'If \`PROACTIVE_PROMPTED\` is \`no\` AND \`TEL_PROMPTED\` is \`yes\`: After telemetry is handled,',
            r'If \`PROACTIVE_PROMPTED\` is \`no\` AND \`LAKE_INTRO\` is \`yes\`: After the lake intro is handled,',
        )
    patch(proactive, _patch_proactive)

search_building = GSTACK_DIR / 'scripts/resolvers/preamble/generate-search-before-building.ts'
if search_building.exists():
    def _patch_search(c):
        return re.sub(
            r'\n\n\*\*Eureka:\*\*[^\n]*\n'
            r'\\`\\`\\`bash\n'
            r'[^\n]*eureka\.jsonl[^\n]*\n'
            r'\\`\\`\\`',
            '', c,
        )
    patch(search_building, _patch_search)

# ─── Phase 1c: shared resolvers + skill-specific ─────────────────────────────

learnings = GSTACK_DIR / 'scripts/resolvers/learnings.ts'
if learnings.exists():
    learnings.write_text(
        "import type { TemplateContext } from './types';\n\n"
        "export function generateLearningsSearch(_ctx: TemplateContext): string {\n"
        "  return '';\n"
        "}\n\n"
        "export function generateLearningsLog(_ctx: TemplateContext): string {\n"
        "  return '';\n"
        "}\n",
        encoding='utf-8',
    )

review_army = GSTACK_DIR / 'scripts/resolvers/review-army.ts'
if review_army.exists():
    def _patch_review_army(c):
        c = re.sub(r'3\. Past learnings for this domain \(if any exist\):.*?4\. Instructions:\n', '3. Instructions:\n', c, flags=re.DOTALL)
        c = re.sub(r"Past learnings: \{learnings or 'none'\}\n\n", '', c)
        return c
    patch(review_army, _patch_review_army)

investigate_tmpl = GSTACK_DIR / 'investigate/SKILL.md.tmpl'
if investigate_tmpl.exists():
    def _patch_investigate(c):
        return re.sub(r'Log the investigation as a learning for future sessions\..*?\{\{LEARNINGS_LOG\}\}\n', '', c, flags=re.DOTALL)
    patch(investigate_tmpl, _patch_investigate)

learn_tmpl = GSTACK_DIR / 'learn/SKILL.md.tmpl'
if learn_tmpl.exists():
    learn_tmpl.write_text(
        "---\nname: learn\npreamble-tier: 2\nversion: 1.0.0\n"
        "description: |\n"
        "  Legacy skill name retained for compatibility. Learnings storage is disabled\n"
        "  by gstack-no-telemetry, so this skill explains there is no persisted memory.\n"
        "triggers:\n  - show learnings\n  - what have we learned\nallowed-tools:\n  - Read\n---\n\n"
        "{{PREAMBLE}}\n\n# Project Learnings Manager\n\n"
        "gstack-no-telemetry disables the learnings system entirely.\n\n"
        "There is no persisted project-memory state to inspect, search, prune, export, or modify.\n",
        encoding='utf-8',
    )

review_ts = GSTACK_DIR / 'scripts/resolvers/review.ts'
if review_ts.exists():
    def _patch_review(c):
        # Match the "3. Append metrics" bash block.
        # Use a positive lookahead for the closing template-literal backtick so
        # we never accidentally consume it.
        return re.sub(
            r'\n3\. Append metrics:\n\\`\\`\\`bash\nmkdir -p[^\n]*\necho[^\n]*spec-review\.jsonl[^\n]*\n\\`\\`\\`\n'
            r'Replace ITERATIONS[^\n]*\n'
            r'(?=`|\\`)' ,
            '\n', c,
        )
    patch(review_ts, _patch_review)

# careful / freeze / guard / unfreeze (v1.26 added unfreeze skill-usage write)
for _p in [
    GSTACK_DIR / 'careful/SKILL.md.tmpl',
    GSTACK_DIR / 'careful/SKILL.md',
    GSTACK_DIR / 'freeze/SKILL.md',
    GSTACK_DIR / 'guard/SKILL.md',
    GSTACK_DIR / 'unfreeze/SKILL.md.tmpl',
    GSTACK_DIR / 'unfreeze/SKILL.md',
]:
    strip_skill_usage(_p)

# retro: remove Eureka Moments paragraph (references eureka.jsonl)
retro_tmpl = GSTACK_DIR / 'retro/SKILL.md.tmpl'
if retro_tmpl.exists():
    c = retro_tmpl.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'\*\*Eureka Moments \(if logged\):\*\* Read[^\n]*eureka\.jsonl[^\n]*\n'
        r'.*?'
        r'\| Eureka Moments \| [^\n]*\|\n',
        '',
        c, flags=re.DOTALL,
    )
    if c != orig:
        retro_tmpl.write_text(c, encoding='utf-8')

# office-hours: only strip skill-usage.jsonl, keep builder-profile.jsonl
oh = GSTACK_DIR / 'office-hours/SKILL.md'
if oh.exists():
    c = oh.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'\n2\. Log the selection to analytics:\n```bash\nmkdir -p[^\n]*\n'
        r'echo[^\n]*skill-usage\.jsonl[^\n]*\n```\n',
        '\n', c,
    )
    c = re.sub(r"echo '[^\n]*skill-usage\.jsonl[^\n]*\n", '', c)
    if c != orig:
        oh.write_text(c, encoding='utf-8')

# ─── Phase 1d: gstack v1.26+ regenerated layout ───────────────────────────────
# v1.26 introduced new code paths in the sub-module generators that the
# v1.6-shaped patches above don't match. Strip them surgically here.

preamble_bash_v126 = GSTACK_DIR / 'scripts/resolvers/preamble/generate-preamble-bash.ts'
if preamble_bash_v126.exists():
    def _patch_bash_v126(c):
        # .pending-* finalize loop
        c = re.sub(
            r"for _PF in \$\(find ~/\.gstack/analytics -maxdepth 1 -name '\.pending-\*' 2>/dev/null\); do\n"
            r'  if \[ -f "\$_PF" \]; then\n'
            r'    if \[ "\$_TEL" != "off" \] && \[ -x "\$\{ctx\.paths\.binDir\}/gstack-telemetry-log" \]; then\n'
            r'      \$\{ctx\.paths\.binDir\}/gstack-telemetry-log [^\n]+\n'
            r'    fi\n'
            r'    rm -f "\$_PF" 2>/dev/null \|\| true\n'
            r'  fi\n'
            r'  break\n'
            r'done\n',
            '', c,
        )
        # slug eval + learnings count block
        c = re.sub(
            r'eval "\$\(\$\{ctx\.paths\.binDir\}/gstack-slug 2>/dev/null\)" 2>/dev/null \|\| true\n'
            r'_LEARN_FILE="\\\$\{GSTACK_HOME:-\$HOME/\.gstack\}/projects/\\\$\{SLUG:-unknown\}/learnings\.jsonl"\n'
            r'if \[ -f "\$_LEARN_FILE" \]; then\n'
            r'  _LEARN_COUNT=\$\(wc -l < "\$_LEARN_FILE"[^\n]+\n'
            r'  echo "LEARNINGS: \$_LEARN_COUNT entries loaded"\n'
            r'  if \[ "\$_LEARN_COUNT" -gt 5 \] 2>/dev/null; then\n'
            r'    \$\{ctx\.paths\.binDir\}/gstack-learnings-search --limit 3[^\n]+\n'
            r'  fi\n'
            r'else\n'
            r'  echo "LEARNINGS: 0"\n'
            r'fi\n',
            '', c,
        )
        # timeline-log line
        c = re.sub(
            r'\$\{ctx\.paths\.binDir\}/gstack-timeline-log [^\n]+\n',
            '', c,
        )
        return c
    patch(preamble_bash_v126, _patch_bash_v126)

completion_v126 = GSTACK_DIR / 'scripts/resolvers/preamble/generate-completion-status.ts'
if completion_v126.exists():
    def _patch_completion_v126(c):
        # Remove "## Operational Self-Improvement" section through "Do not log..."
        c = re.sub(
            r'## Operational Self-Improvement\n\n'
            r'Before completing[^\n]+\n\n'
            r'\\`\\`\\`bash\n'
            r'\$\{ctx\.paths\.binDir\}/gstack-learnings-log [^\n]+\n'
            r'\\`\\`\\`\n\n'
            r'Do not log obvious facts or one-time transient errors\.\n\n',
            '', c,
        )
        # Remove "## Telemetry (run last)" entire section through "Replace ... before running."
        c = re.sub(
            r'## Telemetry \(run last\)\n\n'
            r'.*?'
            r'Replace \\`SKILL_NAME\\`, \\`OUTCOME\\`, and \\`USED_BROWSE\\` before running\.\n\n',
            '', c, flags=re.DOTALL,
        )
        return c
    patch(completion_v126, _patch_completion_v126)

ctx_recovery_v126 = GSTACK_DIR / 'scripts/resolvers/preamble/generate-context-recovery.ts'
if ctx_recovery_v126.exists():
    def _patch_ctx_v126(c):
        # Remove timeline.jsonl tail line + the if-block immediately after
        c = re.sub(
            r'  \[ -f "\$_PROJ/timeline\.jsonl" \] && tail -5 "\$_PROJ/timeline\.jsonl"\n'
            r'  if \[ -f "\$_PROJ/timeline\.jsonl" \]; then\n'
            r'    _LAST=\$\(grep [^\n]+\n'
            r'    \[ -n "\$_LAST" \] && echo "LAST_SESSION: \$_LAST"\n'
            r'    _RECENT_SKILLS=\$\(grep [^\n]+\n'
            r'    \[ -n "\$_RECENT_SKILLS" \] && echo "RECENT_PATTERN: \$_RECENT_SKILLS"\n'
            r'  fi\n',
            '', c,
        )
        # Drop LAST_SESSION/RECENT_PATTERN refs from closing instruction
        c = c.replace(
            "If artifacts are listed, read the newest useful one. If \\`LAST_SESSION\\` or \\`LATEST_CHECKPOINT\\` appears, give a 2-sentence welcome back summary. If \\`RECENT_PATTERN\\` clearly implies a next skill, suggest it once.",
            "If artifacts are listed, read the newest useful one. If \\`LATEST_CHECKPOINT\\` appears, give a 2-sentence welcome back summary."
        )
        return c
    patch(ctx_recovery_v126, _patch_ctx_v126)

review_ts_v126 = GSTACK_DIR / 'scripts/resolvers/review.ts'
if review_ts_v126.exists():
    def _patch_review_v126(c):
        # Remove "3. Append metrics:" bash block (v1.26 shape).
        # Pattern stops BEFORE the closing template-literal backtick (`;) so
        # we don't accidentally truncate the function.
        c = re.sub(
            r'\n\n3\. Append metrics:\n'
            r'\\`\\`\\`bash\n'
            r'mkdir -p ~/\.gstack/analytics\n'
            r"echo '\{[^\n]+spec-review\.jsonl[^\n]+\n"
            r'\\`\\`\\`\n'
            r'Replace ITERATIONS, FOUND, FIXED, REMAINING, SCORE with actual values from the review\.',
            '', c,
        )
        # Remove "### Learnings Logging" plan-file-discrepancies section
        c = re.sub(
            r'### Learnings Logging \(plan-file discrepancies only\)\n\n'
            r'.*?'
            r'These are informational in the review output but too noisy for durable memory\.\n\n',
            '', c, flags=re.DOTALL,
        )
        return c
    patch(review_ts_v126, _patch_review_v126)

# v1.26 gbrain manifests: strip filesystem knowledge-sources that point at
# stripped jsonl files (learnings, timeline, eureka). Without this, the
# regenerated SKILL.md still mentions those globs even though writes are gone.
def _strip_gbrain_jsonl_sources(c):
    return re.sub(
        r'    - id: [^\n]+\n'
        r'      kind: filesystem\n'
        r'      glob: "[^"]+(?:learnings|timeline|eureka)\.jsonl"\n'
        r'      tail: \d+\n'
        r'      render_as: "[^"]+"\n',
        '', c,
    )

for _tmpl in [
    GSTACK_DIR / 'investigate/SKILL.md.tmpl',
    GSTACK_DIR / 'office-hours/SKILL.md.tmpl',
    GSTACK_DIR / 'retro/SKILL.md.tmpl',
]:
    patch(_tmpl, _strip_gbrain_jsonl_sources)

# v1.26 retro: strip skill-usage.jsonl read references (no leak, but tidies output)
def _strip_retro_skill_usage(c):
    # bash: cat skill-usage.jsonl line + its preceding numbered comment
    c = re.sub(
        r'# 12\. gstack skill usage telemetry \(if available\)\n'
        r'cat ~/\.gstack/analytics/skill-usage\.jsonl 2>/dev/null \|\| true\n\n',
        '', c,
    )
    # markdown: Skill Usage paragraph + bash table block + closing instruction
    c = re.sub(
        r'\*\*Skill Usage \(if analytics exist\):\*\* Read `~/\.gstack/analytics/skill-usage\.jsonl`[^\n]+\n\n'
        r'```\n'
        r'\| Skill Usage \| [^\n]+\n'
        r'```\n\n'
        r'If the JSONL file doesn\'t exist or has no entries in the window, skip the Skill Usage row\.\n\n',
        '', c,
    )
    return c

patch(GSTACK_DIR / 'retro/SKILL.md.tmpl', _strip_retro_skill_usage)

print("  patched generator sources", file=sys.stderr)

# ─── Phase 2: neutralize telemetry binaries ───────────────────────────────────

STUB = '#!/usr/bin/env bash\nexit 0\n'
BIN_NAMES = [
    'gstack-analytics',
    'gstack-learnings-log',
    'gstack-learnings-search',
    'gstack-telemetry-log',
    'gstack-telemetry-sync',
    'gstack-timeline-log',
    'gstack-timeline-read',
]
for name in BIN_NAMES:
    b = GSTACK_DIR / 'bin' / name
    if b.exists():
        b.write_text(STUB, encoding='utf-8')
        b.chmod(0o755)

# gstack-codex-probe: stub the two logging functions (sourced, not executed)
codex_probe = GSTACK_DIR / 'bin/gstack-codex-probe'
if codex_probe.exists():
    c = codex_probe.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'(_gstack_codex_log_event\(\) \{).*?^(\})',
        r'\1\n  return 0  # stripped by gstack-no-telemetry\n\2',
        c, flags=re.DOTALL | re.MULTILINE,
    )
    c = re.sub(
        r'(_gstack_codex_log_hang\(\) \{).*?^(\})',
        r'\1\n  return 0  # stripped by gstack-no-telemetry\n\2',
        c, flags=re.DOTALL | re.MULTILINE,
    )
    if c != orig:
        codex_probe.write_text(c, encoding='utf-8')

print("  neutralized telemetry/timeline/learnings binaries", file=sys.stderr)

# ─── Phase 3: patch tests ──────────────────────────────────────────────────────

test_file = GSTACK_DIR / 'test/gen-skill-docs.test.ts'
if test_file.exists():
    c = test_file.read_text(encoding='utf-8')
    c = re.sub(r"  test\('generated SKILL\.md contains telemetry line'.*?\n  \}\);\n\n", '', c, flags=re.DOTALL)
    c = re.sub(r"  test\('preamble \.pending-\\\*.*?\n  \}\);\n\n", '', c, flags=re.DOTALL)
    c = re.sub(r"  test\('preamble-using skills have correct skill name in telemetry'.*?\n  \}\);\n\n", '', c, flags=re.DOTALL)
    c = re.sub(r"describe\('telemetry'.*?\n\}\);\n", '', c, flags=re.DOTALL)
    c = c.replace(
        "content.includes('gstack-config') || content.includes('gstack-update-check') || content.includes('gstack-telemetry-log')",
        "content.includes('gstack-config') || content.includes('gstack-update-check')",
    )
    c = c.replace("    expect(content).toContain('gstack-learnings-search --limit 3');\n", "    expect(content).not.toContain('gstack-learnings-search');\n")
    c = c.replace(
        "      expect(content).toContain('Prior Learnings');\n      expect(content).toContain('gstack-learnings-search');\n",
        "      expect(content).not.toContain('Prior Learnings');\n      expect(content).not.toContain('gstack-learnings-search');\n",
    )
    c = c.replace("      expect(content).toContain('Capture Learnings');\n", "      expect(content).not.toContain('Capture Learnings');\n")
    c = c.replace(
        "expect(content).not.toContain('~/.codex/skills/gstack/bin/gstack-config get telemetry');",
        "// Telemetry removed\n    expect(content).not.toContain('telemetry');",
    )
    test_file.write_text(c, encoding='utf-8')
    print("  patched tests", file=sys.stderr)

PYEOF


# -- Phases 1a-3: run the Python patcher --------------------------------------
python3 "$_TMP" "$GSTACK_DIR"

# -- 4. Regenerate SKILL.md files ---------------------------------------------
echo "  regenerating SKILL.md files..."
(cd "$GSTACK_DIR" && bun run gen:skill-docs >/dev/null)
echo "  regenerated all SKILL.md files"

# -- 4.5. Write Phase 4.5+4.6 Python patcher to temp file --------------------
_TMP2=$(mktemp /tmp/gstack_strip2_XXXXXX.py 2>/dev/null || mktemp)
trap 'rm -f "$_TMP" "$_TMP2"' EXIT

cat > "$_TMP2" << 'PYEOF2'
#!/usr/bin/env python3
"""
Phase 4.5: re-strip careful/freeze/guard/office-hours after gen:skill-docs regeneration.
Phase 4.6: strip .agents/ copy.
"""
from pathlib import Path
import re, sys

GSTACK_DIR = Path(sys.argv[1])

def strip_skill_usage(path: Path) -> None:
    if not path.exists():
        return
    c = path.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'mkdir -p ~/\.gstack/analytics\n'
        r"echo '\{\"skill\":\"[^\"]*\"[^\n]*skill-usage\.jsonl[^\n]*\n",
        '', c,
    )
    c = re.sub(r"echo '[^\n]*skill-usage\.jsonl[^\n]*\n", '', c)
    if c != orig:
        path.write_text(c, encoding='utf-8')

# Phase 4.5: re-patch after regeneration
for _p in [
    GSTACK_DIR / 'careful/SKILL.md',
    GSTACK_DIR / 'freeze/SKILL.md',
    GSTACK_DIR / 'guard/SKILL.md',
    GSTACK_DIR / 'unfreeze/SKILL.md',
]:
    strip_skill_usage(_p)

# retro: re-strip Eureka Moments paragraph after regeneration
retro_md = GSTACK_DIR / 'retro/SKILL.md'
if retro_md.exists():
    c = retro_md.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'\*\*Eureka Moments \(if logged\):\*\* Read[^\n]*eureka\.jsonl[^\n]*\n'
        r'.*?'
        r'\| Eureka Moments \| [^\n]*\|\n',
        '',
        c, flags=re.DOTALL,
    )
    if c != orig:
        retro_md.write_text(c, encoding='utf-8')

oh = GSTACK_DIR / 'office-hours/SKILL.md'
if oh.exists():
    c = oh.read_text(encoding='utf-8')
    orig = c
    c = re.sub(
        r'\n2\. Log the selection to analytics:\n```bash\nmkdir -p[^\n]*\n'
        r'echo[^\n]*skill-usage\.jsonl[^\n]*\n```\n',
        '\n', c,
    )
    c = re.sub(r"echo '[^\n]*skill-usage\.jsonl[^\n]*\n", '', c)
    if c != orig:
        oh.write_text(c, encoding='utf-8')

# Phase 4.6: strip .agents/ copy
STUB = '#!/usr/bin/env bash\nexit 0\n'
BIN_NAMES = [
    'gstack-analytics', 'gstack-learnings-log', 'gstack-learnings-search',
    'gstack-telemetry-log', 'gstack-telemetry-sync',
    'gstack-timeline-log', 'gstack-timeline-read',
]

agents_dir = GSTACK_DIR / '.agents/skills/gstack'
if agents_dir.exists():
    for name in BIN_NAMES:
        b = agents_dir / 'bin' / name
        if b.exists():
            b.write_text(STUB, encoding='utf-8')
            b.chmod(0o755)

    for p in agents_dir.rglob('SKILL.md'):
        c = p.read_text(encoding='utf-8')
        orig = c
        c = re.sub(
            r'_TEL=\$\([^)]*gstack-config get telemetry[^\n]*\)\n'
            r'_TEL_PROMPTED=\$\([^\n]*\)\n'
            r'_TEL_START=\$\([^\n]*\)\n'
            r'_SESSION_ID=[^\n]*\n'
            r'echo "[^\n]*TELEMETRY[^\n]*"\n'
            r'echo "[^\n]*TEL_PROMPTED[^\n]*"\n',
            '', c,
        )
        c = re.sub(
            r'mkdir -p ~/\.gstack/analytics\n'
            r'if \[ "\$_TEL" != "off" \]; then\n'
            r'echo[^\n]*skill-usage\.jsonl[^\n]*\n'
            r'fi\n',
            '', c,
        )
        c = re.sub(
            r'mkdir -p ~/\.gstack/analytics\n'
            r"echo '\{\"skill\":[^\n]*skill-usage\.jsonl[^\n]*\n",
            '', c,
        )
        c = re.sub(r'# zsh-compatible.*?^done\n', '', c, flags=re.DOTALL | re.MULTILINE)
        c = re.sub(r'# Learnings count\n.*?echo "LEARNINGS: 0"\nfi\n', '', c, flags=re.DOTALL)
        c = re.sub(r'# Session timeline: record skill start.*?2>/dev/null &\n', '', c, flags=re.DOTALL)
        c = re.sub(r'## Operational Self-Improvement.*?## Plan Mode Safe Operations', '## Plan Mode Safe Operations', c, flags=re.DOTALL)
        c = re.sub(r'\n_TEL_END=\$\(date.*?2>/dev/null &\nfi\n', '\n', c, flags=re.DOTALL)
        c = re.sub(
            r"(Writing to `~/.gstack/`[^\n]*)analytics,? ?",
            lambda m: m.group(0).replace('analytics, ', '').replace(', analytics', ''),
            c,
        )
        c = re.sub(r'echo[^\n]*skill-usage\.jsonl[^\n]*\n', '', c)
        c = re.sub(r'echo[^\n]*spec-review\.jsonl[^\n]*\n', '', c)
        c = re.sub(r'echo[^\n]*eureka\.jsonl[^\n]*\n', '', c)
        c = re.sub(r'[ \t]*~[^\n]*gstack-learnings-log[^\n]*\n', '', c)
        c = re.sub(r'[ \t]*~[^\n]*gstack-learnings-search[^\n]*\n', '', c)
        c = re.sub(r'[^\n]*timeline\.jsonl[^\n]*\n', '', c)
        if c != orig:
            p.write_text(c, encoding='utf-8')

    print("  stripped .agents/ copy", file=sys.stderr)

# Phase 4.7: strip ~/.codex/skills/gstack* copy (Codex CLI install)
codex_skills = Path.home() / '.codex/skills'
if codex_skills.exists():
    # Stub binaries in the main gstack/ subdir
    codex_main_bin = codex_skills / 'gstack' / 'bin'
    if codex_main_bin.exists():
        for name in BIN_NAMES:
            b = codex_main_bin / name
            if b.exists():
                b.write_text(STUB, encoding='utf-8')
                b.chmod(0o755)

    # Strip telemetry from every gstack* SKILL.md (one main + N prefixed skills)
    for skill_dir in codex_skills.glob('gstack*'):
        if not skill_dir.is_dir():
            continue
        for p in skill_dir.rglob('SKILL.md'):
            c = p.read_text(encoding='utf-8')
            orig = c
            # v1.6 telemetry header
            c = re.sub(
                r'_TEL=\$\([^)]*gstack-config get telemetry[^\n]*\)\n'
                r'_TEL_PROMPTED=\$\([^\n]*\)\n'
                r'_TEL_START=\$\([^\n]*\)\n'
                r'_SESSION_ID=[^\n]*\n'
                r'echo "[^\n]*TELEMETRY[^\n]*"\n'
                r'echo "[^\n]*TEL_PROMPTED[^\n]*"\n',
                '', c,
            )
            c = re.sub(
                r'mkdir -p ~/\.gstack/analytics\n'
                r'if \[ "\$_TEL" != "off" \]; then\n'
                r'echo[^\n]*skill-usage\.jsonl[^\n]*\n'
                r'fi\n',
                '', c,
            )
            c = re.sub(
                r'mkdir -p ~/\.gstack/analytics\n'
                r"echo '\{\"skill\":[^\n]*skill-usage\.jsonl[^\n]*\n",
                '', c,
            )
            c = re.sub(r'# zsh-compatible.*?^done\n', '', c, flags=re.DOTALL | re.MULTILINE)
            c = re.sub(r'# Learnings count\n.*?echo "LEARNINGS: 0"\nfi\n', '', c, flags=re.DOTALL)
            c = re.sub(r'# Session timeline: record skill start.*?2>/dev/null &\n', '', c, flags=re.DOTALL)
            c = re.sub(r'## Operational Self-Improvement.*?## Plan Mode Safe Operations', '## Plan Mode Safe Operations', c, flags=re.DOTALL)
            c = re.sub(r'\n_TEL_END=\$\(date.*?2>/dev/null &\nfi\n', '\n', c, flags=re.DOTALL)
            c = re.sub(
                r"(Writing to `~/.gstack/`[^\n]*)analytics,? ?",
                lambda m: m.group(0).replace('analytics, ', '').replace(', analytics', ''),
                c,
            )
            # v1.26 pending-finalize block (codex variant uses $GSTACK_BIN)
            c = re.sub(
                r"for _PF in \$\(find ~/\.gstack/analytics -maxdepth 1 -name '\.pending-\*' 2>/dev/null\); do\n"
                r'  if \[ -f "\$_PF" \]; then\n'
                r'    if \[ "\$_TEL" != "off" \] && \[ -x "\$GSTACK_BIN/gstack-telemetry-log" \]; then\n'
                r'      \$GSTACK_BIN/gstack-telemetry-log [^\n]+\n'
                r'    fi\n'
                r'    rm -f "\$_PF" 2>/dev/null \|\| true\n'
                r'  fi\n'
                r'  break\n'
                r'done\n',
                '', c,
            )
            # v1.26 slug + learnings count block (codex variant)
            c = re.sub(
                r'eval "\$\(\$GSTACK_BIN/gstack-slug 2>/dev/null\)" 2>/dev/null \|\| true\n'
                r'_LEARN_FILE="\$\{GSTACK_HOME:-\$HOME/\.gstack\}/projects/\$\{SLUG:-unknown\}/learnings\.jsonl"\n'
                r'if \[ -f "\$_LEARN_FILE" \]; then\n'
                r'  _LEARN_COUNT=\$\(wc -l < "\$_LEARN_FILE"[^\n]+\n'
                r'  echo "LEARNINGS: \$_LEARN_COUNT entries loaded"\n'
                r'  if \[ "\$_LEARN_COUNT" -gt 5 \] 2>/dev/null; then\n'
                r'    \$GSTACK_BIN/gstack-learnings-search --limit 3[^\n]+\n'
                r'  fi\n'
                r'else\n'
                r'  echo "LEARNINGS: 0"\n'
                r'fi\n',
                '', c,
            )
            # v1.26 timeline-log line (codex variant)
            c = re.sub(
                r'\$GSTACK_BIN/gstack-timeline-log [^\n]+\n',
                '', c,
            )
            # Multi-line $GSTACK_ROOT/bin/gstack-learnings-log JSON block (review.ts plan-discrepancy)
            c = re.sub(
                r'\$GSTACK_ROOT/bin/gstack-learnings-log \'\{\n'
                r'.*?'
                r"^\}'\n",
                '', c, flags=re.DOTALL | re.MULTILINE,
            )
            # jq-based eureka writes
            c = re.sub(
                r"jq -n[^\n]*>> ~/\.gstack/analytics/eureka\.jsonl[^\n]*\n",
                '', c,
            )
            # Stragglers — wipe any line referencing stripped bins or jsonl files
            c = re.sub(r'echo[^\n]*skill-usage\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'echo[^\n]*spec-review\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'echo[^\n]*eureka\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'cat ~/\.gstack/analytics/skill-usage\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-learnings-log[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-learnings-search[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-timeline-log[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-timeline-read[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-telemetry-log[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*gstack-telemetry-sync[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*timeline\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*learnings\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*eureka\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*spec-review\.jsonl[^\n]*\n', '', c)
            c = re.sub(r'[^\n]*skill-usage\.jsonl[^\n]*\n', '', c)
            if c != orig:
                p.write_text(c, encoding='utf-8')

    print("  stripped ~/.codex/skills/gstack* copy", file=sys.stderr)

PYEOF2

python3 "$_TMP2" "$GSTACK_DIR"

# -- 5. Verify ----------------------------------------------------------------

_SOURCES=""
for _f in \
  "$GSTACK_DIR/scripts/resolvers/preamble.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-preamble-bash.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-telemetry-prompt.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-completion-status.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-context-recovery.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-proactive-prompt.ts" \
  "$GSTACK_DIR/scripts/resolvers/preamble/generate-search-before-building.ts" \
  "$GSTACK_DIR/scripts/resolvers/learnings.ts" \
  "$GSTACK_DIR/scripts/resolvers/review.ts" \
  "$GSTACK_DIR/scripts/resolvers/review-army.ts" \
  "$GSTACK_DIR/investigate/SKILL.md.tmpl" \
  "$GSTACK_DIR/learn/SKILL.md.tmpl" \
  "$GSTACK_DIR/careful/SKILL.md.tmpl"
do
  [ -f "$_f" ] && _SOURCES="$_SOURCES $_f"
done

REMAINING=$(grep -RIn \
  -e 'gstack-telemetry-log' \
  -e 'gstack-telemetry-sync' \
  -e 'gstack-timeline-log' \
  -e 'gstack-timeline-read' \
  -e 'gstack-learnings-log' \
  -e 'gstack-learnings-search' \
  -e 'LEARNINGS:' \
  -e 'Prior Learnings' \
  -e 'Capture Learnings' \
  -e 'timeline.jsonl' \
  -e 'learnings.jsonl' \
  -e 'eureka.jsonl' \
  -e 'spec-review.jsonl' \
  "$GSTACK_DIR"/*/SKILL.md \
  ${_SOURCES} \
  2>/dev/null || true)

_AGENTS_DIR="$GSTACK_DIR/.agents/skills/gstack"
if [ -d "$_AGENTS_DIR" ]; then
  _AGENTS_REMAINING=$(grep -RIn \
    -e 'gstack-telemetry-log' \
    -e 'gstack-timeline-log' \
    -e 'gstack-learnings-log' \
    -e 'gstack-learnings-search' \
    -e 'timeline.jsonl' \
    -e 'learnings.jsonl' \
    -e 'skill-usage.jsonl' \
    "$_AGENTS_DIR"/*/SKILL.md \
    2>/dev/null || true)
  REMAINING="$REMAINING$_AGENTS_REMAINING"
fi

if [ -n "$REMAINING" ]; then
  echo "  WARNING: references still found in:" >&2
  echo "$REMAINING" >&2
  exit 1
fi

echo "strip-telemetry: done -- telemetry, timeline, and learnings removed"
