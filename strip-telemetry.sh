#!/usr/bin/env bash
# ============================================================================
# strip-telemetry.sh -- Remove all telemetry from gstack
#
# gstack (https://github.com/garrytan/gstack) ships with built-in telemetry.
# This script strips it cleanly after every install or upgrade.
#
# Idempotent: safe to run multiple times. Exits gracefully if already clean.
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
if ! grep -q 'generateTelemetryPrompt' "$PREAMBLE" 2>/dev/null; then
  echo "strip-telemetry: telemetry already removed -- nothing to do"
  exit 0
fi

echo "strip-telemetry: patching $GSTACK_DIR ..."

# -- 1. Patch preamble.ts -----------------------------------------------------

# Use a temp file for multi-pass sed (portable across macOS/Linux)
TMP=$(mktemp)

# 1a. Remove telemetry vars from generatePreambleBash
#     Delete from "_TEL=$(" through the "done" that closes the .pending loop
sed '/^_TEL=\$(/,/^done$/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"

# 1b. Remove the analytics mkdir, JSONL write, and zsh comment that precede _TEL
sed '/^mkdir -p ~\/.gstack\/analytics$/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"
sed "/^echo '.*skill-usage\.jsonl/d" "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"
sed '/^# zsh-compatible: use find instead of glob/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"

# 1c. Remove _TEL_START and _SESSION_ID lines
sed '/_TEL_START=\$(date/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"
sed '/_SESSION_ID="/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"

# 1d. Remove TELEMETRY and TEL_PROMPTED echo lines
sed '/echo "TELEMETRY:/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"
sed '/echo "TEL_PROMPTED:/d' "$PREAMBLE" > "$TMP" && mv "$TMP" "$PREAMBLE"

# 1e. Remove the entire generateTelemetryPrompt function and references
python3 -c "
import re, sys
content = open('$PREAMBLE').read()
# Remove generateTelemetryPrompt function
content = re.sub(
    r'function generateTelemetryPrompt\(ctx: TemplateContext\): string \{.*?\n\}\n\n',
    '',
    content,
    flags=re.DOTALL
)
# Remove generateTelemetryPrompt from preamble composition
content = content.replace('    generateTelemetryPrompt(ctx),\n', '')
# Fix proactive prompt: TEL_PROMPTED -> LAKE_INTRO
content = content.replace(
    \"PROACTIVE_PROMPTED\\\` is \\\`no\\\` AND \\\`TEL_PROMPTED\\\` is \\\`yes\\\`: After telemetry is handled,\",
    \"PROACTIVE_PROMPTED\\\` is \\\`no\\\` AND \\\`LAKE_INTRO\\\` is \\\`yes\\\`: After the lake intro is handled,\"
)
# Remove telemetry epilogue from generateCompletionStatus
content = re.sub(
    r'## Telemetry \(run last\).*?remote binary only runs if telemetry is not off and the binary exists\.\n\n',
    '',
    content,
    flags=re.DOTALL
)
# Clean up docstring
content = content.replace(
    'The preamble provides: update checks, session tracking, user preferences,\n * repo mode detection, and telemetry.',
    'The preamble provides: update checks, session tracking, user preferences,\n * and repo mode detection.'
)
content = content.replace(
    'Telemetry data flow:\n *   1. Always: local JSONL append to ~/.gstack/analytics/ (inline, inspectable)\n *   2. If _TEL != \"off\" AND binary exists: gstack-telemetry-log for remote reporting\n */\n',
    '*/\n'
)
# Fix tier comment
content = content.replace('T1: core + upgrade + lake + telemetry + voice', 'T1: core + upgrade + lake + proactive + voice')
open('$PREAMBLE', 'w').write(content)
" 2>/dev/null

echo "  patched preamble.ts"

# -- 2. Delete telemetry binaries ----------------------------------------------

for bin in gstack-telemetry-log gstack-telemetry-sync gstack-analytics; do
  rm -f "$GSTACK_DIR/bin/$bin"
done
echo "  deleted telemetry binaries"

# -- 3. Patch tests ------------------------------------------------------------

if [ -f "$TEST_FILE" ]; then
  python3 -c "
import re
content = open('$TEST_FILE').read()

# Remove 'generated SKILL.md contains telemetry line' test
content = re.sub(
    r\"  test\('generated SKILL\.md contains telemetry line'.*?\n  \}\);\n\n\",
    '',
    content,
    flags=re.DOTALL
)

# Remove 'preamble .pending-* glob is zsh-safe' test
content = re.sub(
    r\"  test\('preamble \.pending-\\\\\* glob is zsh-safe.*?\n  \}\);\n\n\",
    '',
    content,
    flags=re.DOTALL
)

# Remove 'preamble-using skills have correct skill name in telemetry' test
content = re.sub(
    r\"  test\('preamble-using skills have correct skill name in telemetry'.*?\n  \}\);\n\n\",
    '',
    content,
    flags=re.DOTALL
)

# Remove entire describe('telemetry') block
content = re.sub(
    r\"describe\('telemetry'.*?\n\}\);\n\",
    '',
    content,
    flags=re.DOTALL
)

# Update codex path test: remove gstack-telemetry-log reference
content = content.replace(
    \"content.includes('gstack-config') || content.includes('gstack-update-check') || content.includes('gstack-telemetry-log')\",
    \"content.includes('gstack-config') || content.includes('gstack-update-check')\"
)

# Update codex telemetry path assertion
content = content.replace(
    \"expect(content).not.toContain('~/.codex/skills/gstack/bin/gstack-config get telemetry');\",
    \"// Telemetry removed\\n    expect(content).not.toContain('telemetry');\"
)

open('$TEST_FILE', 'w').write(content)
" 2>/dev/null
  echo "  patched tests"
fi

# -- 4. Regenerate SKILL.md files ---------------------------------------------

echo "  regenerating SKILL.md files..."
(cd "$GSTACK_DIR" && bun run gen:skill-docs 2>/dev/null)
echo "  regenerated all SKILL.md files"

# -- 5. Verify -----------------------------------------------------------------

REMAINING=$(grep -rl 'gstack-telemetry-log\|_TEL_START\|TEL_PROMPTED\|generateTelemetryPrompt' "$GSTACK_DIR"/*/SKILL.md "$PREAMBLE" 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
  echo "  WARNING: telemetry references still found in:" >&2
  echo "$REMAINING" >&2
  exit 1
fi

echo "strip-telemetry: done -- all telemetry removed"
