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
# v1.6 refactored preamble.ts into sub-modules under scripts/resolvers/preamble/.
# This script patches both the legacy monolith (v0.x/v1.0-v1.5) and the new
# sub-module layout (v1.6+) so it stays current across upgrades.
#
# Usage: ./strip-telemetry.sh [GSTACK_DIR]
#   GSTACK_DIR defaults to ~/.claude/skills/gstack
# ============================================================================
set -euo pipefail

GSTACK_DIR="${1:-$HOME/.claude/skills/gstack}"

# Legacy monolith path (v0.x / v1.0-v1.5)
PREAMBLE="$GSTACK_DIR/scripts/resolvers/preamble.ts"

# Shared resolver files (all versions)
LEARNINGS="$GSTACK_DIR/scripts/resolvers/learnings.ts"
REVIEW_RESOLVER="$GSTACK_DIR/scripts/resolvers/review.ts"
REVIEW_ARMY_RESOLVER="$GSTACK_DIR/scripts/resolvers/review-army.ts"
INVESTIGATE_TMPL="$GSTACK_DIR/investigate/SKILL.md.tmpl"
LEARN_TMPL="$GSTACK_DIR/learn/SKILL.md.tmpl"
TEST_FILE="$GSTACK_DIR/test/gen-skill-docs.test.ts"

# v1.6+ sub-module paths
PREAMBLE_BASH="$GSTACK_DIR/scripts/resolvers/preamble/generate-preamble-bash.ts"
PREAMBLE_TELEMETRY_PROMPT="$GSTACK_DIR/scripts/resolvers/preamble/generate-telemetry-prompt.ts"
PREAMBLE_COMPLETION_STATUS="$GSTACK_DIR/scripts/resolvers/preamble/generate-completion-status.ts"
PREAMBLE_CONTEXT_RECOVERY="$GSTACK_DIR/scripts/resolvers/preamble/generate-context-recovery.ts"

if [ ! -f "$PREAMBLE" ] && [ ! -f "$PREAMBLE_BASH" ]; then
  echo "strip-telemetry: no preamble found at $GSTACK_DIR -- skipping" >&2
  exit 0
fi

echo "strip-telemetry: patching $GSTACK_DIR ..."

# -- 1a. Patch legacy monolith preamble.ts (v0.x / v1.0-v1.5) -----------------
if [ -f "$PREAMBLE" ]; then
python3 - "$PREAMBLE" "$LEARNINGS" "$REVIEW_RESOLVER" "$REVIEW_ARMY_RESOLVER" "$INVESTIGATE_TMPL" "$LEARN_TMPL" <<'PYEOF'
from pathlib import Path
import re
import sys

preamble = Path(sys.argv[1])
learnings = Path(sys.argv[2])
review_resolver = Path(sys.argv[3])
review_army_resolver = Path(sys.argv[4])
investigate_tmpl = Path(sys.argv[5])
learn_tmpl = Path(sys.argv[6])

content = preamble.read_text(encoding='utf-8')
original = content

content = content.replace(
    " * The preamble provides: update checks, session tracking, user preferences,\n * repo mode detection, and telemetry.\n *\n * Telemetry data flow:\n *   1. Always: local JSONL append to ~/.gstack/analytics/ (inline, inspectable)\n *   2. If _TEL != \"off\" AND binary exists: gstack-telemetry-log for remote reporting\n",
    " * The preamble provides: update checks, user preferences, and repo mode detection.\n",
)
content = content.replace(
    " * The preamble provides: update checks, session tracking, user preferences,\n * and repo mode detection.\n",
    " * The preamble provides: update checks, user preferences, and repo mode detection.\n",
)

# Remove remote telemetry prompt and references
content = re.sub(
    r'\nfunction generateTelemetryPrompt\(.*?\n\}\n',
    '\n',
    content,
    flags=re.DOTALL,
)
content = re.sub(r'[ \t]*generateTelemetryPrompt\(ctx\),\n', '', content)

# Remove telemetry shell block from the preamble bash template
content = re.sub(
    r'_TEL=\$\(.*?^done\n',
    '',
    content,
    flags=re.DOTALL | re.MULTILINE,
)

# Remove local learnings/timeline injection block from the preamble bash template
content = re.sub(
    r'# Learnings count\n.*?^# Check if CLAUDE\.md has routing rules\n',
    '# Check if CLAUDE.md has routing rules\n',
    content,
    flags=re.DOTALL | re.MULTILINE,
)

# Fix proactive prompt dependency after removing telemetry prompt
content = content.replace(
    "If \\`PROACTIVE_PROMPTED\\` is \\`no\\` AND \\`TEL_PROMPTED\\` is \\`yes\\`: After telemetry is handled,\n",
    "If \\`PROACTIVE_PROMPTED\\` is \\`no\\` AND \\`LAKE_INTRO\\` is \\`yes\\`: After the lake intro is handled,\n",
)

# Remove completion-time telemetry/learnings sections
content = re.sub(
    r'## Operational Self-Improvement.*?## Plan Mode Safe Operations',
    '## Plan Mode Safe Operations',
    content,
    flags=re.DOTALL,
)

content = content.replace(
    '- \\`codex exec\\` / \\`codex review\\` (outside voice, plan review, adversarial challenge)\n- Writing to \\`~/.gstack/\\` (config, analytics, review logs, design artifacts, learnings)\n',
    '- \\`codex exec\\` / \\`codex review\\` (outside voice, plan review, adversarial challenge)\n- Writing to \\`~/.gstack/\\` (config, review logs, design artifacts)\n',
)

# Remove timeline-based context recovery and predictive suggestions
content = re.sub(
    r'  # Timeline summary \(last 5 events\)\n.*?  _LATEST_CP=',
    '  _LATEST_CP=',
    content,
    flags=re.DOTALL,
)
content = content.replace(
    'If \\`LAST_SESSION\\` is shown, mention it briefly: "Last session on this branch ran\n/[skill] with [outcome]." If \\`LATEST_CHECKPOINT\\` exists, read it for full context\non where work left off.\n\nIf \\`RECENT_PATTERN\\` is shown, look at the skill sequence. If a pattern repeats\n(e.g., review,ship,review), suggest: "Based on your recent pattern, you probably\nwant /[next skill]."\n\n**Welcome back message:** If any of LAST_SESSION, LATEST_CHECKPOINT, or RECENT ARTIFACTS\nare shown, synthesize a one-paragraph welcome briefing before proceeding:\n"Welcome back to {branch}. Last session: /{skill} ({outcome}). [Checkpoint summary if\navailable]. [Health score if available]." Keep it to 2-3 sentences.',
    'If \\`LATEST_CHECKPOINT\\` exists, read it for full context on where work left off.\n\n**Welcome back message:** If any of LATEST_CHECKPOINT or RECENT ARTIFACTS\nare shown, synthesize a one-paragraph welcome briefing before proceeding:\n"Welcome back to {branch}. [Checkpoint summary if available]. [Health score if\navailable]." Keep it to 2-3 sentences.',
)

content = content.replace(
    'T1: core + upgrade + lake + telemetry + voice',
    'T1: core + upgrade + lake + proactive + voice',
)

# v1.6: comment block split across lines with "model overlays, and\n * telemetry"
content = re.sub(
    r' \* tracking, user preferences, repo mode detection, model overlays, and\n'
    r' \* telemetry\.\n'
    r' \*\n'
    r' \* Telemetry data flow:\n'
    r' \*   1\. Always: local JSONL append to ~/\.gstack/analytics/ \(inline, inspectable\)\n'
    r' \*   2\. If _TEL != "off" AND binary exists: gstack-telemetry-log for remote reporting\n',
    ' * tracking, user preferences, and repo mode detection.\n',
    content,
)

if content == original:
    print("  preamble.ts already stripped or no telemetry block matched", file=sys.stderr)

preamble.write_text(content, encoding='utf-8')
PYEOF
fi

# -- 1b. Patch v1.6+ sub-modules -----------------------------------------------
# In v1.6 the preamble was split into ~20 sub-modules under
# scripts/resolvers/preamble/. Each telemetry concern now lives in its own file.

if [ -f "$PREAMBLE_BASH" ]; then
python3 - "$PREAMBLE_BASH" "$PREAMBLE_TELEMETRY_PROMPT" "$PREAMBLE_COMPLETION_STATUS" "$PREAMBLE_CONTEXT_RECOVERY" <<'PYEOF'
from pathlib import Path
import re
import sys

preamble_bash       = Path(sys.argv[1])
telemetry_prompt    = Path(sys.argv[2])
completion_status   = Path(sys.argv[3])
context_recovery    = Path(sys.argv[4])

# ---- generate-preamble-bash.ts ----
if preamble_bash.exists():
    content = preamble_bash.read_text(encoding='utf-8')
    original = content

    # Remove _TEL / _TEL_PROMPTED / _TEL_START / _SESSION_ID vars + echo lines
    content = re.sub(
        r'_TEL=\$\([^)]*gstack-config get telemetry[^\n]*\)\n'
        r'_TEL_PROMPTED=\$\([^\n]*\)\n'
        r'_TEL_START=\$\([^\n]*\)\n'
        r'_SESSION_ID=[^\n]*\n'
        r'echo "[^\n]*TELEMETRY[^\n]*"\n'
        r'echo "[^\n]*TEL_PROMPTED[^\n]*"\n',
        '',
        content,
    )

    # Remove analytics mkdir + conditional JSONL write block
    content = re.sub(
        r'mkdir -p ~/\.gstack/analytics\n'
        r'if \[ "\$_TEL" != "off" \]; then\n'
        r'echo[^\n]*skill-usage\.jsonl[^\n]*\n'
        r'fi\n',
        '',
        content,
    )

    # Remove .pending-* finalization loop
    content = re.sub(
        r'# zsh-compatible.*?^done\n',
        '',
        content,
        flags=re.DOTALL | re.MULTILINE,
    )

    # Remove learnings count block
    content = re.sub(
        r'# Learnings count\n.*?echo "LEARNINGS: 0"\nfi\n',
        '',
        content,
        flags=re.DOTALL,
    )

    # Remove session timeline start log line
    content = re.sub(
        r'# Session timeline: record skill start.*?2>/dev/null &\n',
        '',
        content,
        flags=re.DOTALL,
    )

    if content == original:
        print("  generate-preamble-bash.ts already stripped or patterns changed", file=sys.stderr)
    preamble_bash.write_text(content, encoding='utf-8')

# ---- generate-telemetry-prompt.ts ----
# Replace entirely - just return empty string, no prompt shown to users
if telemetry_prompt.exists():
    telemetry_prompt.write_text(
        "import type { TemplateContext } from '../types';\n\n"
        "export function generateTelemetryPrompt(_ctx: TemplateContext): string {\n"
        "  return '';\n"
        "}\n",
        encoding='utf-8',
    )

# ---- generate-completion-status.ts ----
# Remove Operational Self-Improvement (learnings-log) + Telemetry (run last) sections
if completion_status.exists():
    content = completion_status.read_text(encoding='utf-8')
    original = content

    # Strip both sections in one pass (they appear consecutively before Plan Mode Safe Ops)
    content = re.sub(
        r'## Operational Self-Improvement\n.*?(?=## Plan Mode Safe Operations)',
        '',
        content,
        flags=re.DOTALL,
    )

    # Remove analytics mention from Plan Mode Safe Operations allowed list
    content = re.sub(
        r"(writes to `~~/\.gstack/`[^\n]*analytics[^\n]*\n)",
        lambda m: m.group(0).replace(', analytics', '').replace('analytics, ', ''),
        content,
    )
    # Handle the compact single-line form used in v1.6
    content = re.sub(
        r'(writes to `~~/\.gstack/` \(config), analytics,? (review logs)',
        r'\1, \2',
        content,
    )

    if content == original:
        print("  generate-completion-status.ts already stripped or patterns changed", file=sys.stderr)
    completion_status.write_text(content, encoding='utf-8')

# ---- generate-context-recovery.ts ----
# Remove timeline.jsonl bash reads + LAST_SESSION / RECENT_PATTERN instruction text
if context_recovery.exists():
    content = context_recovery.read_text(encoding='utf-8')
    original = content

    # Remove the timeline tail + cross-session injection bash block
    content = re.sub(
        r'  # Timeline summary \(last 5 events\)\n.*?  _LATEST_CP=',
        '  _LATEST_CP=',
        content,
        flags=re.DOTALL,
    )

    # Remove LAST_SESSION and RECENT_PATTERN instruction paragraphs
    content = re.sub(
        r"If `LAST_SESSION` is shown.*?want /\[next skill\]\.\"\n\n",
        '',
        content,
        flags=re.DOTALL,
    )

    # Fix welcome-back message to drop LAST_SESSION reference
    content = content.replace(
        '**Welcome back message:** If any of LAST_SESSION, LATEST_CHECKPOINT, or RECENT ARTIFACTS',
        '**Welcome back message:** If any of LATEST_CHECKPOINT or RECENT ARTIFACTS',
    )
    content = re.sub(
        r'"Welcome back to \{branch\}\. Last session: /\[skill\] \(\[outcome\]\)\. \[Checkpoint summary if\navailable\]\.',
        '"Welcome back to {branch}. [Checkpoint summary if available].',
        content,
    )

    if content == original:
        print("  generate-context-recovery.ts already stripped or patterns changed", file=sys.stderr)
    context_recovery.write_text(content, encoding='utf-8')
PYEOF
fi

# -- 1c. Patch shared resolver sources (all versions) -------------------------
python3 - "$LEARNINGS" "$REVIEW_RESOLVER" "$REVIEW_ARMY_RESOLVER" "$INVESTIGATE_TMPL" "$LEARN_TMPL" <<'PYEOF'
from pathlib import Path
import re
import sys

learnings           = Path(sys.argv[1])
review_resolver     = Path(sys.argv[2])
review_army_resolver= Path(sys.argv[3])
investigate_tmpl    = Path(sys.argv[4])
learn_tmpl          = Path(sys.argv[5])

# Remove generic learnings resolver output entirely
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

# Remove custom learnings logging from the review resolver
if review_resolver.exists():
    review_content = review_resolver.read_text(encoding='utf-8')
    review_content = re.sub(
        r'### Learnings Logging \(plan-file discrepancies only\).*?### Integration with Scope Drift Detection',
        '### Integration with Scope Drift Detection',
        review_content,
        flags=re.DOTALL,
    )
    review_resolver.write_text(review_content, encoding='utf-8')

# Remove learnings lookup from the review-army resolver used by /review and /ship
if review_army_resolver.exists():
    review_army_content = review_army_resolver.read_text(encoding='utf-8')
    review_army_content = re.sub(
        r'3\. Past learnings for this domain \(if any exist\):.*?4\. Instructions:\n',
        '3. Instructions:\n',
        review_army_content,
        flags=re.DOTALL,
    )
    review_army_content = re.sub(
        r"Past learnings: \{learnings or 'none'\}\n\n",
        '',
        review_army_content,
    )
    review_army_resolver.write_text(review_army_content, encoding='utf-8')

# Remove custom investigation learning capture from the investigate template
if investigate_tmpl.exists():
    investigate_content = investigate_tmpl.read_text(encoding='utf-8')
    investigate_content = re.sub(
        r'Log the investigation as a learning for future sessions\..*?\{\{LEARNINGS_LOG\}\}\n',
        '',
        investigate_content,
        flags=re.DOTALL,
    )
    investigate_tmpl.write_text(investigate_content, encoding='utf-8')

# Make /learn inert so the repo no longer claims to manage learnings
if learn_tmpl.exists():
    learn_tmpl.write_text(
        "---\n"
        "name: learn\n"
        "preamble-tier: 2\n"
        "version: 1.0.0\n"
        "description: |\n"
        "  Legacy skill name retained for compatibility. Learnings storage is disabled\n"
        "  by gstack-no-telemetry, so this skill now explains that there is no persisted\n"
        "  project memory to inspect.\n"
        "triggers:\n"
        "  - show learnings\n"
        "  - what have we learned\n"
        "  - manage project learnings\n"
        "allowed-tools:\n"
        "  - Read\n"
        "---\n"
        "\n"
        "{{PREAMBLE}}\n"
        "\n"
        "# Project Learnings Manager\n"
        "\n"
        "gstack-no-telemetry disables the learnings system entirely.\n"
        "\n"
        "There is no persisted project-memory state to inspect, search, prune, export, or modify.\n"
        "\n"
        "If you want zero retained session memory, this is the expected behavior.\n",
        encoding='utf-8',
    )
PYEOF

echo "  patched generator sources"

# -- 2. Neutralize write-path binaries ----------------------------------------

for bin in \
  gstack-analytics \
  gstack-learnings-log \
  gstack-learnings-search \
  gstack-telemetry-log \
  gstack-telemetry-sync \
  gstack-timeline-log \
  gstack-timeline-read
do
  cat > "$GSTACK_DIR/bin/$bin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$GSTACK_DIR/bin/$bin"
done
echo "  neutralized telemetry/timeline/learnings binaries"

# -- 3. Patch tests ------------------------------------------------------------

if [ -f "$TEST_FILE" ]; then
python3 - "$TEST_FILE" <<'PYEOF'
from pathlib import Path
import re
import sys

test_file = Path(sys.argv[1])
content = test_file.read_text(encoding='utf-8')

content = re.sub(
    r"  test\('generated SKILL\.md contains telemetry line'.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r"  test\('preamble \.pending-\\\*.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r"  test\('preamble-using skills have correct skill name in telemetry'.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL,
)
content = re.sub(
    r"describe\('telemetry'.*?\n\}\);\n",
    '',
    content,
    flags=re.DOTALL,
)
content = content.replace(
    "content.includes('gstack-config') || content.includes('gstack-update-check') || content.includes('gstack-telemetry-log')",
    "content.includes('gstack-config') || content.includes('gstack-update-check')",
)
content = content.replace(
    "    expect(content).toContain('gstack-learnings-search --limit 3');\n",
    "    expect(content).not.toContain('gstack-learnings-search');\n",
)
content = content.replace(
    "      expect(content).toContain('Prior Learnings');\n      expect(content).toContain('gstack-learnings-search');\n",
    "      expect(content).not.toContain('Prior Learnings');\n      expect(content).not.toContain('gstack-learnings-search');\n",
)
content = content.replace(
    "      expect(content).toContain('Capture Learnings');\n",
    "      expect(content).not.toContain('Capture Learnings');\n",
)
content = content.replace(
    "expect(content).not.toContain('~/.codex/skills/gstack/bin/gstack-config get telemetry');",
    "// Telemetry removed\n    expect(content).not.toContain('telemetry');",
)

test_file.write_text(content, encoding='utf-8')
PYEOF
  echo "  patched tests"
fi

# -- 4. Regenerate SKILL.md files ---------------------------------------------

echo "  regenerating SKILL.md files..."
(cd "$GSTACK_DIR" && bun run gen:skill-docs >/dev/null)
echo "  regenerated all SKILL.md files"

# -- 5. Verify ----------------------------------------------------------------

# Build the list of source files to check (only files that exist)
_VERIFY_SOURCES=""
for f in "$PREAMBLE" "$PREAMBLE_BASH" "$PREAMBLE_TELEMETRY_PROMPT" "$PREAMBLE_COMPLETION_STATUS" "$PREAMBLE_CONTEXT_RECOVERY" "$LEARNINGS" "$REVIEW_RESOLVER" "$REVIEW_ARMY_RESOLVER" "$INVESTIGATE_TMPL" "$LEARN_TMPL"; do
  [ -f "$f" ] && _VERIFY_SOURCES="$_VERIFY_SOURCES $f"
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
  "$GSTACK_DIR"/*/SKILL.md $_VERIFY_SOURCES 2>/dev/null || true)

if [ -n "$REMAINING" ]; then
  echo "  WARNING: references still found in:" >&2
  echo "$REMAINING" >&2
  exit 1
fi

echo "strip-telemetry: done -- telemetry, timeline, and learnings removed"
