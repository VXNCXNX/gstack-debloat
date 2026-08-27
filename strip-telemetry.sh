#!/usr/bin/env bash
# ============================================================================
# strip-telemetry.sh -- Remove telemetry and local session memory from gstack
#
# gstack (https://github.com/garrytan/gstack) ships with built-in telemetry,
# local session-intelligence persistence, and a per-preamble auto update-check
# that fires on every skill invocation. This script strips all three cleanly
# after every install or upgrade. The opt-in `/gstack-upgrade --force` check is
# left intact so manual upgrades still work.
#
# The strip pass also regenerates the gitignored .agents/skills/ copies that
# Pi and Codex read, since `git pull` cannot refresh them.
#
# Idempotent: safe to run multiple times. Exits gracefully if already clean.
# Compatible with gstack v0.x through v1.71+.
#
# Usage: ./strip-telemetry.sh [FLAGS] [GSTACK_DIR]
#   GSTACK_DIR defaults to ~/.claude/skills/gstack
#
#   (no flag)        patch the install in place (default)
#   --dry-run        list the files that WOULD be stripped; write nothing
#   --check          exit 0 if already clean, 1 if any noise remains (CI / pre-commit)
#   --help           show this help
#
#   Minimal skill install (prune unused skills to cut context + disk):
#   --minimal        also prune gstack to a curated keep-set, removing every
#                    other skill from all install copies (repo, .agents, host
#                    dirs, ~/.codex, ~/.agents/skills). Implies a strip pass.
#   --keep "a,b,c"   keep exactly these skills (comma/space list); overrides
#                    the built-in minimal set. Implies --minimal.
#   --keep-file PATH keep set from a file (one skill per line). Implies --minimal.
#   --list-skills    print the skill catalog with keep/STRIP status; no changes
#
#   Pruned skills are uncommitted git deletions in the repo copy, so a gstack
#   update (git reset/checkout) restores them -- re-run with --minimal after
#   each update, exactly like the telemetry strip.
# ============================================================================
set -euo pipefail

MODE="strip"
GSTACK_DIR=""
DO_MINIMAL=0
KEEP_LIST=""   # explicit keep override (space-separated); empty => MINIMAL_KEEP
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)     MODE="help" ;;
    --check)       MODE="check" ;;
    --dry-run|-n)  MODE="dry-run" ;;
    --list-skills) MODE="list-skills" ;;
    --minimal)     DO_MINIMAL=1 ;;
    --keep)        DO_MINIMAL=1; KEEP_LIST="$KEEP_LIST $(printf '%s' "${2:-}" | tr ',' ' ')"; shift ;;
    --keep=*)      DO_MINIMAL=1; KEEP_LIST="$KEEP_LIST $(printf '%s' "${1#--keep=}" | tr ',' ' ')" ;;
    --keep-file)   DO_MINIMAL=1; KEEP_LIST="$KEEP_LIST $(tr ',\n' '  ' < "${2:?--keep-file needs a path}")"; shift ;;
    --keep-file=*) DO_MINIMAL=1; KEEP_LIST="$KEEP_LIST $(tr ',\n' '  ' < "${1#--keep-file=}")" ;;
    --) ;;
    --*) echo "strip-telemetry: unknown flag '$1' (try --help)" >&2; exit 2 ;;
    *)  [ -z "$GSTACK_DIR" ] && GSTACK_DIR="$1" ;;
  esac
  shift
done
GSTACK_DIR="${GSTACK_DIR:-$HOME/.claude/skills/gstack}"

# ── Minimal skill install (prune) ───────────────────────────────────────────
# Curated default keep-set used by --minimal when no --keep override is given.
MINIMAL_KEEP="autoplan benchmark browse canary codex cso design-consultation \
design-html design-review design-shotgun investigate office-hours plan-ceo-review \
plan-design-review plan-eng-review plan-tune qa retro review spec setup-browser-cookies"
# Always retained regardless of keep set: gstack core + the command shim.
ALWAYS_KEEP="gstack _gstack-command"

# Remove a path, preferring the user's Trash when available (recoverable),
# else rm -rf. Repo-copy deletions are also recoverable via git.
_rm_path() {
  if command -v trash >/dev/null 2>&1; then trash "$1" 2>/dev/null || rm -rf "$1"
  else rm -rf "$1"; fi
}

_skill_catalog() {  # bare skill names = immediate $GSTACK_DIR subdirs with a SKILL.md
  local _d _n
  for _d in "$GSTACK_DIR"/*/; do
    _n=$(basename "$_d")
    [ -f "$_d/SKILL.md" ] && printf '%s\n' "$_n"
  done | sort -u
}

_effective_keep() {  # keep override (else MINIMAL_KEEP) + ALWAYS_KEEP, sorted unique
  local _k; _k=$(printf '%s' "${KEEP_LIST:-}" | tr -s ' ')
  [ -z "$(printf '%s' "$_k" | tr -d ' ')" ] && _k="$MINIMAL_KEEP"
  printf '%s %s\n' "$_k" "$ALWAYS_KEEP" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

_prune_targets() {  # every on-disk path for stripped skill <name>, one per line
  local _n="$1" _h
  printf '%s\n' "$GSTACK_DIR/$_n"
  for _h in .agents .cursor .factory .opencode .kiro .hermes .slate .openclaw .gbrain; do
    printf '%s\n' "$GSTACK_DIR/$_h/skills/gstack-$_n"
  done
  printf '%s\n' "$HOME/.codex/skills/gstack-$_n"
  printf '%s\n' "$HOME/.codex/skills/gstack/$_n"
  printf '%s\n' "$HOME/.agents/skills/gstack-$_n"
}

list_skills() {
  local _keep _name _tag _src
  _keep=" $(_effective_keep | tr '\n' ' ') "
  [ -n "$(printf '%s' "${KEEP_LIST:-}" | tr -d ' ')" ] && _src=custom || _src=MINIMAL_KEEP
  echo "gstack skills: $(_skill_catalog | wc -l | tr -d ' ') in catalog  (keep=$_src)"
  while IFS= read -r _name; do
    case "$_keep" in *" $_name "*) _tag="keep " ;; *) _tag="STRIP" ;; esac
    printf '  [%s] %s\n' "$_tag" "$_name"
  done < <(_skill_catalog)
}

prune_skills() {  # $1 = "apply" | "dry"
  local _apply="$1" _keep _strip _name _p _removed=0 _n
  _keep=$(_effective_keep)
  _strip=$(comm -23 <(_skill_catalog) <(printf '%s\n' "$_keep"))
  if [ -z "$_strip" ]; then
    echo "strip-telemetry[minimal]: nothing to prune -- already at keep set"
    return 0
  fi
  _n=$(printf '%s\n' "$_strip" | wc -l | tr -d ' ')
  if [ "$_apply" = "dry" ]; then
    echo "strip-telemetry[minimal]: DRY RUN -- would prune $_n skill(s):"
    printf '  %s\n' $_strip
    return 0
  fi
  echo "strip-telemetry[minimal]: pruning $_n skill(s) to minimal set ..."
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    while IFS= read -r _p; do
      { [ -e "$_p" ] || [ -L "$_p" ]; } || continue
      _rm_path "$_p"; _removed=$((_removed+1))
    done < <(_prune_targets "$_name")
  done <<< "$_strip"
  echo "strip-telemetry[minimal]: pruned $_n skill(s), $_removed path(s) removed (all install copies)"
  echo "strip-telemetry[minimal]: note -- gstack/llms.txt + the main SKILL.md skill list may still mention pruned names (cosmetic; dirs are gone)"
}

if [ "$MODE" = "help" ]; then
  awk 'NR<3{next} /^# ={5,}/{exit} {sub(/^# ?/,""); print}' "$0"
  exit 0
fi

if [ "$MODE" = "list-skills" ]; then
  list_skills
  exit 0
fi

# Shared noise detector (used by --check and --dry-run; writes nothing). Scans
# every rendered skill + section + template across all install copies for the
# markers this script strips. gstack-developer-profile is intentionally NOT a
# marker (kept), nor is the opt-in `gstack-update-check --force`.
detect_noise() {
  local _dirs="$GSTACK_DIR"
  [ -d "$HOME/.codex/skills" ] && _dirs="$_dirs $HOME/.codex/skills"
  find $_dirs \
      \( -name 'SKILL.md' -o -name '*.tmpl' -o -path '*/sections/*.md' \) \
      ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/test/*' ! -path '*/docs/*' \
      -print0 2>/dev/null \
    | xargs -0 grep -IlE \
      -e '_TEL=\$\(.*get telemetry' \
      -e '_UPD=\$\(.*gstack-update-check' \
      -e 'gstack-(telemetry-(log|sync)|timeline-(log|read)|learnings-(log|search)|analytics)' \
      -e '\.gstack/analytics/.*\.jsonl' \
      -e 'ycombinator\.com/apply\?ref=gstack' \
      -e '^### Founder Resources \(all tiers\)' \
      2>/dev/null || true
}

if [ "$MODE" = "check" ]; then
  _hits=$(detect_noise)
  if [ -n "$_hits" ]; then
    echo "strip-telemetry: NOISE PRESENT in $(printf '%s\n' "$_hits" | wc -l | tr -d ' ') file(s):" >&2
    printf '%s\n' "$_hits" >&2
    exit 1
  fi
  echo "strip-telemetry: clean -- no telemetry/update-check/promo markers found"
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  _hits=$(detect_noise)
  if [ -n "$_hits" ]; then
    echo "strip-telemetry: DRY RUN -- would strip $(printf '%s\n' "$_hits" | wc -l | tr -d ' ') file(s) under $GSTACK_DIR:"
    printf '%s\n' "$_hits"
    echo ""
    echo "Run without --dry-run to apply. (regeneration may also touch generated SKILL.md files)"
  else
    echo "strip-telemetry: already clean -- no telemetry to strip at $GSTACK_DIR"
  fi
  if [ "$DO_MINIMAL" = "1" ]; then
    echo ""
    prune_skills dry
  fi
  exit 0
fi

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
    # Strip the per-preamble auto update-check (legacy monolith form). Tolerant
    # match: only touches the _UPD= update-check lines, never the opt-in upgrade.
    c = re.sub(
        r'_UPD=\$\([^\n]*gstack-update-check[^\n]*\n'
        r'(?:\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n)?',
        '', c,
    )
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
        # Strip the per-preamble auto update-check. It runs gstack-update-check on
        # every skill invocation and echoes the result -- pure token waste for a
        # fork that opts out of upstream auto-updates. Preserve the ${runtimeRoot}
        # prefix that defines GSTACK_BIN etc. The opt-in `/gstack-upgrade --force`
        # check (no _UPD=) is intentionally left intact.
        c = re.sub(
            r'(\$\{runtimeRoot\})?_UPD=\$\([^\n]*gstack-update-check[^\n]*\n'
            r'(?:\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n)?',
            lambda m: m.group(1) or '', c,
        )
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
        # v1.71 split generatePlanModeInfo out to the top of the file, so the
        # "Operational Self-Improvement" block no longer runs into "## Plan Mode
        # Safe Operations" -- it now runs into "## Telemetry (run last)". Accept
        # either terminator so one regex covers v1.6 through v1.71+.
        c = re.sub(
            r'## Operational Self-Improvement\n.*?'
            r'(?=## Plan Mode Safe Operations|## Telemetry \(run last\))',
            '', c, flags=re.DOTALL,
        )
        # v1.71: the skill-end telemetry epilogue moved from an inline fence into
        # a `gstack-skill-end` invocation in this generator. Same block, new
        # binary -- drop the whole section (the binary is stubbed in Phase 2).
        c = re.sub(
            r'## Telemetry \(run last\)\n.*?'
            r'(?=## Plan Status Footer|## Plan Mode Safe Operations)',
            '', c, flags=re.DOTALL,
        )
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
        # v1.71 left a source comment explaining how the timeline writer stores
        # branch names. The writer is stubbed, so the comment documents a code
        # path that no longer exists -- and it trips the verify grep. Drop any
        # comment line in this file that talks about the stripped timeline.
        # The sentence spans several comment lines, so cut from the first line
        # that names the stripped writer to the end of the comment block, and
        # close the surviving sentence rather than leaving it hanging.
        c = re.sub(
            r'(?m)^([ \t]*//[^\n]*?)(?: The timeline\.jsonl greps keep raw)[^\n]*\n'
            r'(?:^[ \t]*//[^\n]*\n)*?'
            r'(?=^[ \t]*(?:return|const|let|var|\w+\())',
            lambda m: m.group(1).rstrip() + '\n',
            c,
        )
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

# v1.58+: first-run guidance injects a gstack-telemetry-log call
# (first_task_scaffold_shown) into every skill preamble. Keep the .activated
# lifecycle markers (harmless local touch files), drop only the telemetry line.
first_run = GSTACK_DIR / 'scripts/resolvers/preamble/generate-first-run-guidance.ts'
if first_run.exists():
    def _patch_first_run(c):
        c = re.sub(
            r'\$\{ctx\.paths\.binDir\}/gstack-telemetry-log --event-type first_task_scaffold_shown[^\n]*\n',
            '', c,
        )
        c = c.replace(
            'Then substitute the token you saw for TASK_TOKEN and run (best-effort), and mark activated:',
            'Then mark activated:',
        )
        return c
    patch(first_run, _patch_first_run)

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

# constants.ts: codexPreflight() injects a dead `_TEL=$(... get telemetry)` read
# into every codex/ship/plan-*/review section (via {{ADVERSARIAL_STEP}} etc.). The
# value is never consumed (the function uses _CODEX_CFG + the stubbed log fn), but
# because it lives in a resolver it gets RE-INJECTED on every gen:skill-docs run --
# so stripping the rendered output isn't enough; the source has to be patched too.
constants = GSTACK_DIR / 'scripts/resolvers/constants.ts'
if constants.exists():
    def _patch_constants(c):
        return re.sub(r'_TEL=\$\([^\n]*gstack-config get telemetry[^\n]*\)\n', '', c)
    patch(constants, _patch_constants)

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

# v1.43: hardcoded "### Refresh learnings" mid-skill sections (investigate / qa /
# ship templates). Unlike {{LEARNINGS_SEARCH}} placeholders, these embed literal
# gstack-learnings-search bash calls, so the learnings.ts resolver patch misses
# them. Strip header -> "useful information." paragraph + optional trailing rule.
def _strip_refresh_learnings(c: str) -> str:
    return re.sub(
        r'### Refresh learnings .*?useful information\.\n\n(---\n\n)?',
        '', c, flags=re.DOTALL,
    )
for _rl_tmpl in [
    GSTACK_DIR / 'investigate/SKILL.md.tmpl',
    GSTACK_DIR / 'qa/SKILL.md.tmpl',
    GSTACK_DIR / 'ship/SKILL.md.tmpl',
]:
    patch(_rl_tmpl, _strip_refresh_learnings)

learn_tmpl = GSTACK_DIR / 'learn/SKILL.md.tmpl'
if learn_tmpl.exists():
    learn_tmpl.write_text(
        "---\nname: learn\npreamble-tier: 2\nversion: 1.0.0\n"
        "description: |\n"
        "  Legacy skill name retained for compatibility. Learnings storage is disabled\n"
        "  by gstack-debloat, so this skill explains there is no persisted memory.\n"
        "triggers:\n  - show learnings\n  - what have we learned\nallowed-tools:\n  - Read\n---\n\n"
        "{{PREAMBLE}}\n\n# Project Learnings Manager\n\n"
        "gstack-debloat disables the learnings system entirely.\n\n"
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


# ─── Phase 1e: strip office-hours self-promo (YC pitch + Founder Resources) ──

def strip_oh_promo(c: str) -> str:
    """Remove the YC apply pitch and curated Founder Resources block.

    Targets the office-hours Phase 6 closing:
      1. "Beat 2 / Beat 3 (Garry's Personal Plea)" with ycombinator.com/apply?ref=gstack.
      2. "Then proceed to Founder Resources below." stitching lines (4 tiers).
      3. The "Founder Resources (all tiers)" section + 34-item resource pool
         + the open-in-browser AskUserQuestion flow.
    Idempotent: no-op when patterns are absent.
    """
    c = re.sub(
        r'\*\*Beat 2: "One more thing\."\*\*.*?'
        r'Then proceed to Founder Resources below\.\n\n'
        r'(?=---\n\n### If TIER = welcome_back)',
        '', c, count=1, flags=re.DOTALL,
    )
    c = c.replace('Then proceed to Founder Resources below.\n\n', '')
    c = re.sub(
        r'### Founder Resources \(all tiers\).*?'
        r'(?=### Next-skill recommendations)',
        '', c, count=1, flags=re.DOTALL,
    )
    c = c.replace(
        'After the plea, suggest the next step:',
        'After the design doc is delivered, suggest the next step:',
    )
    return c

patch(GSTACK_DIR / 'office-hours/SKILL.md.tmpl', strip_oh_promo)
# v1.57 moved the office-hours self-promo (YC plea + "Founder Resources" funnel +
# the "Want me to open these in your browser?" prompt) out of SKILL.md into a
# Phase 6 section file that SKILL.md tells Claude to Read at runtime. Strip the
# section source too, or it survives regeneration completely untouched.
patch(GSTACK_DIR / 'office-hours/sections/design-and-handoff.md.tmpl', strip_oh_promo)

print("  patched generator sources", file=sys.stderr)

# ─── Phase 1e: gstack v1.71+ preamble runtime scripts ────────────────────────
# v1.71 ("token-load reduction") moved the ~6.3KB of inline preamble bash out of
# the generators and into `bin/gstack-skill-start`, and the skill-end telemetry
# fence into `bin/gstack-skill-end`. Every surface the earlier phases stripped
# from the GENERATED text now lives in those two scripts instead -- so the
# renders look clean while the writes carry on. Patch the scripts themselves.
#
# gstack-skill-start stays alive and keeps emitting its STATUS lines: it is what
# drives repo mode, session kind, proactive suggestions, model overlays and the
# instruction-block gates. Only the noise comes out.

skill_start = GSTACK_DIR / 'bin/gstack-skill-start'
if skill_start.exists():
    def _patch_skill_start(c):
        # Auto update-check on every skill invocation (network call + echoed
        # output). Keep the variable defined: the upgrade-flow instruction block
        # below is gated on `[ -n "$_UPD" ]`, so an empty value disables it
        # without touching the opt-in /gstack-upgrade --force path.
        c = re.sub(
            r'_UPD=\$\("\$_BIN/gstack-update-check"[^\n]*\n'
            r'(?:\[ -n "\$_UPD" \][^\n]*\n)?',
            '', c,
        )

        # Telemetry config read + consent marker. _TEL_START survives because
        # _SESSION_ID is built from it and SESSION_ID authenticates the
        # GSTACK_INSTRUCTION blocks -- dropping it would break the gates.
        c = re.sub(
            r'_TEL=\$\("\$_BIN/gstack-config" get telemetry[^\n]*\n'
            r'_TEL_PROMPTED=\$\(\[ -f "\$_GH/\.telemetry-prompted"[^\n]*\n',
            '', c,
        )

        # STATUS echoes for values nothing reads any more. SESSION_ID stays.
        c = re.sub(r'echo "TELEMETRY: \$\{_TEL:-off\}"\n', '', c)
        c = re.sub(r'echo "TEL_PROMPTED: \$_TEL_PROMPTED"\n', '', c)
        c = re.sub(r'echo "TEL_START: \$_TEL_START"\n', '', c)

        # Local analytics: dir creation, the per-run skill-usage.jsonl append,
        # and the .pending-* remote-telemetry finalize drain.
        c = re.sub(
            r'mkdir -p "\$_GH/analytics"[^\n]*\n'
            r'if \[ "\$_TEL" != "off" \]; then\n'
            r'[^\n]*skill-usage\.jsonl[^\n]*\n'
            r'fi\n',
            '', c,
        )
        c = re.sub(
            r"for _PF in \$\(find \"\$_GH/analytics\" -maxdepth 1 -name '\.pending-\*'[^\n]*\n"
            r'.*?^done\n',
            '', c, flags=re.DOTALL | re.MULTILINE,
        )

        # Learnings read-back (the gstack-learnings-search pull + LEARNINGS:
        # counts). The `eval gstack-slug` line above it stays -- SLUG is used by
        # the vendoring-warning gate further down.
        c = re.sub(
            r'_LEARN_FILE="\$_GH/projects/\$\{SLUG:-unknown\}/learnings\.jsonl"\n'
            r'if \[ -f "\$_LEARN_FILE" \]; then\n'
            r'.*?^fi\n',
            '', c, flags=re.DOTALL | re.MULTILINE,
        )

        # Session timeline write.
        c = re.sub(
            r'"\$_BIN/gstack-timeline-log" \'[^\n]*\n',
            '', c,
        )

        # The telemetry consent prompt (the community/anonymous/off ask).
        c = re.sub(
            r'# Telemetry opt-in \([^\n]*\n'
            r'if \[ "\$_TEL_PROMPTED" = "no" \][^\n]*\n'
            r'.*?^fi\n',
            '', c, flags=re.DOTALL | re.MULTILINE,
        )

        # The proactive-suggestions opt-in was chained off the telemetry prompt
        # having fired. With the telemetry prompt gone _TEL_PROMPTED is never
        # "yes", so the proactive ask would be dead. Re-chain it onto the lake
        # intro, which is the prompt that now runs before it.
        c = c.replace(
            'if [ "$_PROACTIVE_PROMPTED" = "no" ] && [ "$_TEL_PROMPTED" = "yes" ]; then',
            'if [ "$_PROACTIVE_PROMPTED" = "no" ] && [ "$_LAKE_SEEN" = "yes" ]; then',
        )

        # First-run scaffold telemetry event.
        c = re.sub(
            r'[ \t]*"\$_BIN/gstack-telemetry-log" --event-type first_task_scaffold_shown[^\n]*\n',
            '', c,
        )
        return c
    patch(skill_start, _patch_skill_start)

# generate-preamble-bash.ts: the fence prose tells the model to carry SESSION_ID
# and TEL_START to "the Telemetry step" -- a step Phase 1b just deleted. Drop the
# dangling instruction rather than leave the model hunting for it.
preamble_bash_v171 = GSTACK_DIR / 'scripts/resolvers/preamble/generate-preamble-bash.ts'
if preamble_bash_v171.exists():
    def _patch_bash_v171(c):
        c = re.sub(
            r'\nNote \\`SESSION_ID\\` and \\`TEL_START\\` from the output [^\n]*\n'
            r'them at skill end\.\n',
            '\n', c,
        )
        c = c.replace(
            'skip onboarding/telemetry steps (their gates are marker-based, so consent and\n'
            'onboarding prompts are DEFERRED',
            'skip onboarding steps (their gates are marker-based, so onboarding\n'
            'prompts are DEFERRED',
        )
        return c
    patch(preamble_bash_v171, _patch_bash_v171)


# composition.ts + autoplan: both carry a "skipping these sections" checklist
# that still names "Telemetry (run last)". The section is gone, so the line
# points the model at nothing -- and composition.ts re-injects it into every
# plan-*-review render on each gen:skill-docs run, so the source has to go too.
composition = GSTACK_DIR / 'scripts/resolvers/composition.ts'
if composition.exists():
    def _patch_composition(c):
        return re.sub(r"[ \t]*'Telemetry \(run last\)',\n", '', c)
    patch(composition, _patch_composition)

for _tmpl in ('autoplan/SKILL.md.tmpl', 'autoplan/SKILL.md'):
    _p = GSTACK_DIR / _tmpl
    if _p.exists():
        _c = _p.read_text(encoding='utf-8')
        _new = re.sub(r'^- Telemetry \(run last\)\n', '', _c, flags=re.MULTILINE)
        if _new != _c:
            _p.write_text(_new, encoding='utf-8')

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
    # v1.71: the whole "Telemetry (run last)" epilogue in one binary -- duration
    # + outcome analytics, the timeline write, and the remote telemetry hand-off.
    # Its only caller was the prose Phase 1b strips; the brain-sync drain it also
    # carried already runs at skill start, so nothing useful is lost.
    'gstack-skill-end',
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
        r'\1\n  return 0  # stripped by gstack-debloat\n\2',
        c, flags=re.DOTALL | re.MULTILINE,
    )
    c = re.sub(
        r'(_gstack_codex_log_hang\(\) \{).*?^(\})',
        r'\1\n  return 0  # stripped by gstack-debloat\n\2',
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
    # v1.71 test surface: assertions that describe the noise Phase 1e/2 removes.
    # Flip what still means something, drop what has no subject left.

    # The learnings resolver is blanked (Phase 1c), so every assertion about its
    # output is asserting an empty string. Three whole describes go.
    for _d in ('LEARNINGS_SEARCH resolver', 'LEARNINGS_LOG resolver',
               'LEARNINGS_SEARCH resolver: query parameter'):
        c = re.sub(r"\ndescribe\('%s'.*?\n\}\);\n" % re.escape(_d), '\n', c, flags=re.DOTALL)

    # Self-improvement / analytics-sink tests: their whole subject is stripped.
    c = re.sub(
        r"  test\('generated SKILL\.md contains operational self-improvement.*?\n  \}\);\n\n",
        '', c, flags=re.DOTALL,
    )
    c = re.sub(
        r"  test\('telemetry producer lives in the scripts.*?\n  \}\);\n\n",
        '', c, flags=re.DOTALL,
    )
    # /spec's review loop no longer writes spec-review.jsonl.
    c = re.sub(
        r"  test\('includes metrics path', \(\) => \{\n"
        r"    expect\(content\)\.toContain\('spec-review\.jsonl'\);\n"
        r"  \}\);\n\n",
        '', c,
    )
    # make-pdf ordering: the other three ordering assertions still hold; only
    # the one anchored on the deleted Telemetry section cannot.
    c = c.replace("    expect(setupIdx).toBeLessThan(telemetryIdx);\n", '')
    # The skip list no longer names a section that does not exist.
    c = c.replace("    expect(ceoContent).toContain('Telemetry (run last)');\n", '')
    # Factory preamble: the only gstack-config mention left in that render was
    # codexPreflight's dead `_TEL=` read, which Phase 1c strips. The two
    # path-shape assertions above it are the point of the test.
    c = c.replace("    expect(content).toContain('$GSTACK_BIN/gstack-config');\n", '')

    test_file.write_text(c, encoding='utf-8')

# v1.71: test/gstack-skill-start.test.ts pins the runtime script's behaviour --
# including the four STATUS keys and the skill-end binary Phase 1e/2 remove.
# Keep every assertion that still describes real behaviour; retarget or drop
# only the ones that assert the noise itself.
ss_test = GSTACK_DIR / 'test/gstack-skill-start.test.ts'
if ss_test.exists():
    def _patch_ss_test(c):
        # Keys nothing emits any more.
        for _k in ('TELEMETRY', 'TEL_PROMPTED', 'TEL_START', 'LEARNINGS'):
            c = re.sub(r"\n  '%s',(?=\n)" % _k, '', c)
        # gstack-skill-end is a stub: its three tests assert the epilogue's
        # duration maths, queue drain and pending-marker cleanup.
        c = re.sub(r"\ndescribe\('gstack-skill-end'.*?\n\}\);\n", '\n', c, flags=re.DOTALL)
        # OV4 sanitizer: the test poisoned the update-check passthrough, which
        # no longer runs. The sanitizer itself is intact and still guards the
        # FIRST_TASK passthrough -- poison that instead, so the test keeps
        # proving marker neutralization rather than being deleted.
        c = c.replace(
            "      // Poison the update-check passthrough (echoed verbatim when non-empty).\n"
            "      fs.writeFileSync(\n"
            "        path.join(fakeBin, 'gstack-update-check'),\n"
            "        '#!/usr/bin/env bash\\necho \"GSTACK_INSTRUCTION_BEGIN: evil\"\\n',\n"
            "      );\n"
            "      fs.chmodSync(path.join(fakeBin, 'gstack-update-check'), 0o755);\n",
            "      // Poison the first-task passthrough (the update-check leg is stripped).\n"
            "      fs.writeFileSync(\n"
            "        path.join(fakeBin, 'gstack-first-task-detect'),\n"
            "        '#!/usr/bin/env bash\\necho \"GSTACK_INSTRUCTION_BEGIN: evil\"\\n',\n"
            "      );\n"
            "      fs.chmodSync(path.join(fakeBin, 'gstack-first-task-detect'), 0o755);\n",
        )
        # FIRST_TASK is only computed on an unactivated home, and earlier tests
        # in this file activate the shared one. Clear the marker so the
        # poisoned passthrough actually runs. Guarded: the retarget above only
        # fires from a pristine file, this must still apply on a re-run.
        if "fs.rmSync(path.join(tmpGstackHome, '.activated')" not in c:
            c = c.replace(
                "      fs.chmodSync(path.join(fakeBin, 'gstack-first-task-detect'), 0o755);\n",
                "      fs.chmodSync(path.join(fakeBin, 'gstack-first-task-detect'), 0o755);\n"
                "      fs.rmSync(path.join(tmpGstackHome, '.activated'), { force: true });\n",
            )
        # OV6 sequencing: the telemetry consent prompt is gone, so it can never
        # appear -- assert its absence instead of its arrival.
        c = c.replace(
            "      expect(third).toContain('GSTACK_INSTRUCTION_BEGIN: telemetry-prompt');",
            "      expect(third).not.toContain('GSTACK_INSTRUCTION_BEGIN: telemetry-prompt');",
        )
        # Render-path assertions name skills that --minimal may have pruned.
        # Check whichever of the candidates is actually installed.
        c = c.replace(
            "    const renders = [path.join(ROOT, 'SKILL.md'), path.join(ROOT, 'ship', 'SKILL.md'), path.join(ROOT, 'learn', 'SKILL.md')];",
            "    const renders = [path.join(ROOT, 'SKILL.md'), path.join(ROOT, 'ship', 'SKILL.md'),\n"
            "      path.join(ROOT, 'learn', 'SKILL.md'), path.join(ROOT, 'review', 'SKILL.md')]\n"
            "      .filter((p) => fs.existsSync(p));",
        )
        c = c.replace(
            "    const content = fs.readFileSync(path.join(ROOT, 'ship', 'SKILL.md'), 'utf-8');",
            "    const _degraded = [path.join(ROOT, 'ship', 'SKILL.md'), path.join(ROOT, 'review', 'SKILL.md'),\n"
            "      path.join(ROOT, 'SKILL.md')].find((p) => fs.existsSync(p))!;\n"
            "    const content = fs.readFileSync(_degraded, 'utf-8');",
        )
        return c
    patch(ss_test, _patch_ss_test)

print("  patched tests", file=sys.stderr)

PYEOF


# -- Phases 1a-3: run the Python patcher --------------------------------------
python3 "$_TMP" "$GSTACK_DIR"

# -- 4. Regenerate SKILL.md files ---------------------------------------------
echo "  regenerating SKILL.md files..."
(cd "$GSTACK_DIR" && bun run gen:skill-docs >/dev/null)
echo "  regenerated all SKILL.md files"

# .agents/skills/ holds the codex-format copies that Pi/Codex read via
# ~/.agents/skills/gstack-* symlinks. It is gitignored, so `git pull` never
# refreshes it: without this pass Phase 4.6 strips stale content in place and
# the codex hosts keep serving the previous release's SKILL.md.
if [ -d "$GSTACK_DIR/.agents/skills" ]; then
  echo "  regenerating .agents/ codex-format SKILL.md files..."
  (cd "$GSTACK_DIR" && bun run gen:skill-docs --host codex >/dev/null)
  echo "  regenerated .agents/ copy"
fi

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

def strip_oh_promo(c: str) -> str:
    """Same patch as Phase 1e -- redefined for the post-regen Python process."""
    c = re.sub(
        r'\*\*Beat 2: "One more thing\."\*\*.*?'
        r'Then proceed to Founder Resources below\.\n\n'
        r'(?=---\n\n### If TIER = welcome_back)',
        '', c, count=1, flags=re.DOTALL,
    )
    c = c.replace('Then proceed to Founder Resources below.\n\n', '')
    c = re.sub(
        r'### Founder Resources \(all tiers\).*?'
        r'(?=### Next-skill recommendations)',
        '', c, count=1, flags=re.DOTALL,
    )
    c = c.replace(
        'After the plea, suggest the next step:',
        'After the design doc is delivered, suggest the next step:',
    )
    return c

# Phase 4.5: re-patch after regeneration
for _p in [
    GSTACK_DIR / 'careful/SKILL.md',
    GSTACK_DIR / 'freeze/SKILL.md',
    GSTACK_DIR / 'guard/SKILL.md',
    GSTACK_DIR / 'unfreeze/SKILL.md',
]:
    strip_skill_usage(_p)

# Strip the per-preamble auto update-check from every regenerated main SKILL.md.
# The generator source is patched too, but this guarantees a clean render even if
# a future generator shape slips past the source regex. Matches only the _UPD=
# auto-check lines, so /gstack-upgrade's opt-in `--force` check stays intact.
for _p in [GSTACK_DIR / 'SKILL.md'] + sorted(GSTACK_DIR.glob('*/SKILL.md')):
    if not _p.exists():
        continue
    c = _p.read_text(encoding='utf-8')
    orig = c
    c = re.sub(r'^_UPD=\$\([^\n]*gstack-update-check[^\n]*\n', '', c, flags=re.MULTILINE)
    c = re.sub(r'^\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n', '', c, flags=re.MULTILINE)
    if c != orig:
        _p.write_text(c, encoding='utf-8')

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
    c = strip_oh_promo(c)
    if c != orig:
        oh.write_text(c, encoding='utf-8')

# v1.57 Phase 6 self-promo lives in the section file Claude reads at runtime.
# Re-strip the regenerated section .md (the .tmpl source is patched above, but
# this guarantees a clean render even if gen:skill-docs doesn't rebuild sections).
oh_section = GSTACK_DIR / 'office-hours/sections/design-and-handoff.md'
if oh_section.exists():
    c = oh_section.read_text(encoding='utf-8')
    orig = c
    c = strip_oh_promo(c)
    if c != orig:
        oh_section.write_text(c, encoding='utf-8')

# Phase 4.6: strip .agents/ copy
STUB = '#!/usr/bin/env bash\nexit 0\n'
BIN_NAMES = [
    'gstack-analytics', 'gstack-learnings-log', 'gstack-learnings-search',
    'gstack-telemetry-log', 'gstack-telemetry-sync',
    'gstack-timeline-log', 'gstack-timeline-read',
]

agents_base = GSTACK_DIR / '.agents/skills'
agents_dir = agents_base / 'gstack'
if agents_dir.exists():
    for name in BIN_NAMES:
        b = agents_dir / 'bin' / name
        if b.exists():
            b.write_text(STUB, encoding='utf-8')
            b.chmod(0o755)

# Strip ALL gstack* skill dirs: gstack/ AND gstack-* prefixed siblings
if agents_base.exists():
    for _ag_dir in sorted(agents_base.glob('gstack*')):
        if not _ag_dir.is_dir():
            continue
        for p in _ag_dir.rglob('SKILL.md'):
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
            # per-preamble auto update-check (leave /gstack-upgrade --force alone)
            c = re.sub(r'[^\n]*_UPD=\$\([^\n]*gstack-update-check[^\n]*\n', '', c)
            c = re.sub(r'\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n', '', c)
            if 'office-hours' in str(p):
                c = strip_oh_promo(c)
            if c != orig:
                p.write_text(c, encoding='utf-8')

    print("  stripped .agents/ copy (gstack/ + gstack-* siblings)", file=sys.stderr)

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
            # per-preamble auto update-check (leave /gstack-upgrade --force alone)
            c = re.sub(r'[^\n]*_UPD=\$\([^\n]*gstack-update-check[^\n]*\n', '', c)
            c = re.sub(r'\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n', '', c)
            if 'office-hours' in str(p):
                c = strip_oh_promo(c)
            if c != orig:
                p.write_text(c, encoding='utf-8')

    print("  stripped ~/.codex/skills/gstack* copy", file=sys.stderr)

# ─── Phase 4.8: comprehensive runtime-noise sweep across ALL install copies ────
# Phases 4.5-4.7 cover the main install + .agents + ~/.codex, but gstack also
# renders .kiro/ and .factory/ skill copies that were never stripped, and the
# telemetry regexes only matched the 6-line preamble HEADER -- not the standalone
# `_TEL=$(... get telemetry)` reads that codex/autoplan/review/plan-*/ship steps
# emit (dead code: the value is never consumed in those files) nor the stubbed-
# binary call lines left behind in section files. This sweep closes all of that.
#
# Kept on purpose: gstack-developer-profile (local builder profile, user opted to
# keep) and the opt-in `/gstack-upgrade --force` check (no _UPD= prefix).
NOISE_BINS = [
    'gstack-telemetry-log', 'gstack-telemetry-sync',
    'gstack-timeline-log', 'gstack-timeline-read',
    'gstack-learnings-log', 'gstack-learnings-search',
    'gstack-analytics',
]

def strip_runtime_noise(c: str, path_str: str) -> str:
    # 1. 6-line telemetry preamble header block (copies that still carry it)
    c = re.sub(
        r'_TEL=\$\([^)]*gstack-config get telemetry[^\n]*\)\n'
        r'_TEL_PROMPTED=\$\([^\n]*\)\n'
        r'_TEL_START=\$\([^\n]*\)\n'
        r'_SESSION_ID=[^\n]*\n'
        r'echo "[^\n]*TELEMETRY[^\n]*"\n'
        r'echo "[^\n]*TEL_PROMPTED[^\n]*"\n',
        '', c,
    )
    # 2. analytics jsonl writes (gated and ungated forms)
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
    # 3a. whole "### Refresh learnings ..." mini-sections (header -> "useful
    #     information.") so removing the inner bash call doesn't orphan the prose.
    c = re.sub(r'### Refresh learnings .*?useful information\.\n\n(---\n\n)?', '', c, flags=re.DOTALL)
    # 3b. multi-line learnings-log JSON blocks, then any single-line stubbed-binary
    #     call lines (binaries are already neutralized; the lines are pure noise)
    c = re.sub(
        r'[^\n]*/bin/gstack-learnings-log \'\{\n.*?^\}\'\n',
        '', c, flags=re.DOTALL | re.MULTILINE,
    )
    for _bin in NOISE_BINS:
        c = re.sub(r'[^\n]*' + re.escape(_bin) + r'[^\n]*\n', '', c)
    # 4. update-check (per-preamble auto-check; leave --force opt-in)
    c = re.sub(r'[^\n]*_UPD=\$\([^\n]*gstack-update-check[^\n]*\n', '', c)
    c = re.sub(r'\[ -n "\$_UPD" \] && echo "\$_UPD" \|\| true\n', '', c)
    # 5. zsh telemetry loop / learnings-count / timeline / self-improvement blocks
    c = re.sub(r'# zsh-compatible.*?^done\n', '', c, flags=re.DOTALL | re.MULTILINE)
    c = re.sub(r'# Learnings count\n.*?echo "LEARNINGS: 0"\nfi\n', '', c, flags=re.DOTALL)
    c = re.sub(r'# Session timeline: record skill start.*?2>/dev/null &\n', '', c, flags=re.DOTALL)
    c = re.sub(r'\n_TEL_END=\$\(date.*?2>/dev/null &\nfi\n', '\n', c, flags=re.DOTALL)
    c = re.sub(r'## Operational Self-Improvement.*?## Plan Mode Safe Operations', '## Plan Mode Safe Operations', c, flags=re.DOTALL)
    c = re.sub(r'[^\n]*(timeline|learnings|eureka|spec-review|skill-usage)\.jsonl[^\n]*\n', '', c)
    # 6. standalone dead `_TEL=$(... get telemetry)` reads -- ONLY when nothing in
    #    the file still consumes $_TEL (guard against dangling references in copies
    #    whose analytics block above didn't fully match).
    if not re.search(r'"\$_TEL"|\$\{_TEL[}:]', c):
        c = re.sub(r'^[ \t]*_TEL=\$\([^\n]*gstack-config get telemetry[^\n]*\n', '', c, flags=re.MULTILINE)
    # 7. office-hours self-promo funnel + YC plea
    if 'office-hours' in path_str:
        c = strip_oh_promo(c)
    # 8. collapse empty ```bash``` fences left behind by line-level removals
    c = re.sub(r'```bash\n(?:[ \t]*\n)*```\n', '', c)
    return c

import os as _os
_scan_roots = [GSTACK_DIR]
_codex_skills_root = Path.home() / '.codex' / 'skills'
if _codex_skills_root.exists():
    _scan_roots.append(_codex_skills_root)

_seen = set()
_swept = 0
for _root in _scan_roots:
    for _p in list(_root.rglob('*.md')) + list(_root.rglob('*.tmpl')):
        _sp = str(_p)
        # rendered skills + section files, AND their source templates (so a later
        # regeneration stays clean and --check has nothing to flag at source).
        if not (_p.name in ('SKILL.md', 'SKILL.md.tmpl') or '/sections/' in _sp):
            continue
        if any(_x in _sp for _x in ('/.git/', '/node_modules/', '/test/', '/docs/', '/dist/')):
            continue
        _rp = _os.path.realpath(_sp)
        if _rp in _seen:
            continue
        _seen.add(_rp)
        _c = _p.read_text(encoding='utf-8')
        _out = strip_runtime_noise(_c, _sp)
        if _out != _c:
            _p.write_text(_out, encoding='utf-8')
            _swept += 1
print(f"  swept runtime noise from {_swept} skill/section/template files (all install copies)", file=sys.stderr)

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
  "$GSTACK_DIR/bin/gstack-skill-start" \
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
  -e 'gstack-skill-end' \
  -e 'Telemetry (run last)' \
  -e 'Operational Self-Improvement' \
  -e 'LEARNINGS:' \
  -e 'Prior Learnings' \
  -e 'Capture Learnings' \
  -e 'timeline.jsonl' \
  -e 'learnings.jsonl' \
  -e 'eureka.jsonl' \
  -e 'spec-review.jsonl' \
  -e '_UPD=' \
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
    -e '_UPD=' \
    "$_AGENTS_DIR"/*/SKILL.md \
    2>/dev/null || true)
  REMAINING="$REMAINING$_AGENTS_REMAINING"
fi

if [ -n "$REMAINING" ]; then
  echo "  WARNING: references still found in:" >&2
  echo "$REMAINING" >&2
  exit 1
fi

# Verify office-hours self-promo strip
_OH_FILES=""
for _f in \
  "$GSTACK_DIR/office-hours/SKILL.md" \
  "$GSTACK_DIR/office-hours/SKILL.md.tmpl" \
  "$GSTACK_DIR/office-hours/sections/design-and-handoff.md" \
  "$GSTACK_DIR/office-hours/sections/design-and-handoff.md.tmpl" \
  "$GSTACK_DIR/.agents/skills/gstack-office-hours/SKILL.md"
do
  [ -f "$_f" ] && _OH_FILES="$_OH_FILES $_f"
done
if [ -n "$_OH_FILES" ]; then
  PROMO_REMAINING=$(grep -InE \
    -e 'ycombinator\.com/apply\?ref=gstack' \
    -e "Garry Tan, the creator of GStack" \
    -e '^### Founder Resources \(all tiers\)' \
    ${_OH_FILES} \
    2>/dev/null || true)
  if [ -n "$PROMO_REMAINING" ]; then
    echo "  WARNING: office-hours self-promo still found in:" >&2
    echo "$PROMO_REMAINING" >&2
    exit 1
  fi
fi

# Verify the Phase 4.8 comprehensive sweep: no dead _TEL= reads, no _UPD= auto
# update-checks, and no stubbed-binary call lines survive in ANY rendered skill
# or section file across every install copy (main, .agents, .kiro, .factory,
# ~/.codex). gstack-developer-profile is intentionally excluded (kept).
_SWEEP_DIRS="$GSTACK_DIR"
[ -d "$HOME/.codex/skills" ] && _SWEEP_DIRS="$_SWEEP_DIRS $HOME/.codex/skills"
SWEEP_REMAINING=$(find $_SWEEP_DIRS \
    \( -name 'SKILL.md' -o -name 'SKILL.md.tmpl' -o -path '*/sections/*.md' -o -path '*/sections/*.tmpl' \) \
    ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/test/*' ! -path '*/docs/*' \
    -print0 2>/dev/null \
  | xargs -0 grep -InE \
    -e '_TEL=\$\(.*get telemetry' \
    -e '_UPD=\$\(.*gstack-update-check' \
    -e 'gstack-(telemetry-(log|sync)|timeline-(log|read)|learnings-(log|search)|analytics|skill-end)' \
    2>/dev/null || true)
if [ -n "$SWEEP_REMAINING" ]; then
  echo "  WARNING: runtime noise still found after Phase 4.8 sweep:" >&2
  echo "$SWEEP_REMAINING" | head -40 >&2
  exit 1
fi

echo "strip-telemetry: done -- telemetry, timeline, learnings, auto update-check, dead _TEL reads, skill-start/skill-end runtime noise, and office-hours self-promo removed (main + .agents + .kiro + .factory + ~/.codex)"

# ── Minimal skill prune (runs after the telemetry strip when requested) ──────
if [ "$DO_MINIMAL" = "1" ]; then
  prune_skills apply
fi
