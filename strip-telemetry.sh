#!/usr/bin/env bash
# ============================================================================
# strip-telemetry.sh -- Remove all telemetry from gstack
#
# gstack (https://github.com/garrytan/gstack) ships with built-in telemetry.
# This script strips it cleanly after every install or upgrade.
#
# Idempotent: safe to run multiple times. Exits gracefully if already clean.
# Compatible with gstack v0.x and v1.x.
#
# Usage: ./strip-telemetry.sh [GSTACK_DIR]
#   GSTACK_DIR defaults to ~/.claude/skills/gstack
# ============================================================================
set -euo pipefail

GSTACK_DIR="${1:-$HOME/.claude/skills/gstack}"
PREAMBLE="$GSTACK_DIR/scripts/resolvers/preamble.ts"
TEST_FILE="$GSTACK_DIR/test/gen-skill-docs.test.ts"

if [ ! -f "$PREAMBLE" ]; then
  echo "strip-telemetry: preamble.ts not found at $PREAMBLE -- skipping" >&2
  exit 0
fi

# Guard: skip if already stripped
if ! grep -q 'generateTelemetryPrompt\|gstack-telemetry-log' "$PREAMBLE" 2>/dev/null; then
  echo "strip-telemetry: telemetry already removed -- nothing to do"
  exit 0
fi

echo "strip-telemetry: patching $GSTACK_DIR ..."

# -- 1. Patch preamble.ts (all via python3 for reliability) -------------------

python3 << PYEOF
import re, sys

with open('$PREAMBLE', 'r') as f:
    content = f.read()

original = content

# 1a. Remove generateTelemetryPrompt function (v0 + v1 compatible)
content = re.sub(
    r'\nfunction generateTelemetryPrompt\(.*?\n\}\n',
    '',
    content,
    flags=re.DOTALL
)

# 1b. Remove generateTelemetryPrompt from preamble composition array
content = re.sub(r'[ \t]*generateTelemetryPrompt\(ctx\),\n', '', content)

# 1c. Fix proactive prompt gate: TEL_PROMPTED -> LAKE_INTRO (v0 used TEL_PROMPTED as gate)
content = content.replace(
    "PROACTIVE_PROMPTED\` is \`no\` AND \`TEL_PROMPTED\` is \`yes\`: After telemetry is handled,",
    "PROACTIVE_PROMPTED\` is \`no\` AND \`LAKE_INTRO\` is \`yes\`: After the lake intro is handled,"
)

# 1d. Remove telemetry epilogue section (## Telemetry (run last) ... through the closing paragraph)
#     Handles variation in ending text across versions
content = re.sub(
    r'## Telemetry \(run last\).*?(?:remote binary only runs if telemetry is not off and the binary exists\.|The local JSONL always logs\..*?)\n\n',
    '',
    content,
    flags=re.DOTALL
)

# 1e. Remove _TEL, _TEL_START, _SESSION_ID, analytics lines from bash template strings
#     These may appear as literal bash inside TS template literals
content = re.sub(r'^[ \t]*_TEL=\$\(.*?^[ \t]*done\n', '', content, flags=re.DOTALL | re.MULTILINE)
content = re.sub(r'^[ \t]*_TEL_START=\$\(date.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*_SESSION_ID=".*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*echo "TELEMETRY:.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*echo "TEL_PROMPTED:.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*mkdir -p ~/\.gstack/analytics.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*echo .*skill-usage\.jsonl.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^[ \t]*# zsh-compatible: use find instead of glob.*\n', '', content, flags=re.MULTILINE)

# 1f. Remove telemetry data flow docstring block
content = re.sub(
    r' \* Telemetry data flow:\n(?: \*.*\n)*',
    '',
    content
)

# 1g. Clean up telemetry mention in class/function docstring
content = content.replace(
    ' * repo mode detection, and telemetry.',
    ' * and repo mode detection.'
)

# 1h. Fix tier comment if present
content = content.replace(
    'T1: core + upgrade + lake + telemetry + voice',
    'T1: core + upgrade + lake + proactive + voice'
)

if content == original:
    print("  WARNING: preamble.ts unchanged -- patterns may not have matched", file=sys.stderr)
    sys.exit(1)

with open('$PREAMBLE', 'w') as f:
    f.write(content)

print("  patched preamble.ts")
PYEOF

# -- 2. Delete telemetry binaries ---------------------------------------------

for bin in gstack-telemetry-log gstack-telemetry-sync gstack-analytics; do
  rm -f "$GSTACK_DIR/bin/$bin" "$GSTACK_DIR/bin/${bin}.exe"
done
echo "  deleted telemetry binaries"

# -- 3. Patch tests -----------------------------------------------------------

if [ -f "$TEST_FILE" ]; then
  python3 << PYEOF
import re

with open('$TEST_FILE', 'r') as f:
    content = f.read()

# Remove telemetry-related test cases
content = re.sub(
    r"  test\('generated SKILL\.md contains telemetry line'.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL
)
content = re.sub(
    r"  test\('preamble \.pending-\\\*.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL
)
content = re.sub(
    r"  test\('preamble-using skills have correct skill name in telemetry'.*?\n  \}\);\n\n",
    '',
    content,
    flags=re.DOTALL
)
content = re.sub(
    r"describe\('telemetry'.*?\n\}\);\n",
    '',
    content,
    flags=re.DOTALL
)

# Update path/assertion tests
content = content.replace(
    "content.includes('gstack-config') || content.includes('gstack-update-check') || content.includes('gstack-telemetry-log')",
    "content.includes('gstack-config') || content.includes('gstack-update-check')"
)
content = content.replace(
    "expect(content).not.toContain('~/.codex/skills/gstack/bin/gstack-config get telemetry');",
    "// Telemetry removed\n    expect(content).not.toContain('telemetry');"
)

with open('$TEST_FILE', 'w') as f:
    f.write(content)
PYEOF
  echo "  patched tests"
fi

# -- 4. Regenerate SKILL.md files ---------------------------------------------

echo "  regenerating SKILL.md files..."
(cd "$GSTACK_DIR" && bun run gen:skill-docs 2>/dev/null)
echo "  regenerated all SKILL.md files"

# -- 5. Verify ----------------------------------------------------------------
# Note: checkpoint/SKILL.md uses _TEL_START as a session duration timer (not
# telemetry), so we exclude it from the check.

REMAINING=$(grep -rl 'gstack-telemetry-log\|TEL_PROMPTED\|generateTelemetryPrompt' \
  "$GSTACK_DIR"/*/SKILL.md "$PREAMBLE" 2>/dev/null || true)
# Also check for _TEL_START but exclude checkpoint (legitimate timing use)
TEL_START_REMAINING=$(grep -rl '_TEL_START' \
  "$GSTACK_DIR"/*/SKILL.md "$PREAMBLE" 2>/dev/null \
  | grep -v 'checkpoint/SKILL.md' || true)

if [ -n "$REMAINING" ] || [ -n "$TEL_START_REMAINING" ]; then
  echo "  WARNING: telemetry references still found in:" >&2
  [ -n "$REMAINING" ] && echo "$REMAINING" >&2
  [ -n "$TEL_START_REMAINING" ] && echo "$TEL_START_REMAINING" >&2
  exit 1
fi

echo "strip-telemetry: done -- all telemetry removed"
