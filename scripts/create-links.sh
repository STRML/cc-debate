#!/bin/bash
# create-links.sh — create stable symlinks under ~/.claude pointing into this
# plugin, so command files can use literal paths that survive plugin updates.
# Run once after install or update via /debate:setup.

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SELF_DIR/.." && pwd)"

STATUS=0

# `ln -sfn` does not replace a real directory — it creates a nested link inside
# it and exits 0. Left unchecked, every refresh would report success while
# commands kept reading whatever is already there. A dangling symlink is fine to
# replace (-e is false for it, -L is true), so only reject non-symlinks.
link_dir() {
  local target="$1" link="$2" what="$3"

  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "❌ $link already exists and is not a symlink."
    echo ""
    echo "   Refreshing it would create a nested link inside it and report"
    echo "   success, leaving commands on the existing contents. Move it aside:"
    echo ""
    echo "   mv \"$link\" \"$link.bak\""
    echo ""
    echo "   Then re-run /debate:setup."
    STATUS=1
    return 1
  fi

  if ln -sfn "$target" "$link" 2>/dev/null; then
    echo "✅ Symlink created: $link -> $target"
    return 0
  fi

  echo "⚠️  Sandbox blocked symlink creation for $what (ln -sfn is restricted to project dir)."
  echo ""
  echo "   Run this once from your regular terminal (outside Claude Code):"
  echo ""
  echo "   ln -sfn \"$target\" \"$link\""
  echo ""
  echo "   Or add to ~/.claude/settings.json:"
  echo "     \"sandbox\": { \"allowedPaths\": [\"$link\"] }"
  STATUS=1
  return 1
}

link_dir "$SELF_DIR" "$HOME/.claude/debate-scripts" "scripts"

# The workflow panel gets its own link rather than a file dropped into
# ~/.claude/workflows, which belongs to the user and may hold their own scripts.
# Invoke it by path: Workflow({scriptPath: "~/.claude/debate-workflows/review-panel.js"}).
#
# Guarded on existence so an older plugin version in the cache, which shipped no
# workflows directory, does not leave a dangling link behind.
if [ -d "$PLUGIN_DIR/workflows" ]; then
  link_dir "$PLUGIN_DIR/workflows" "$HOME/.claude/debate-workflows" "workflows"
fi

if [ "$STATUS" -eq 0 ]; then
  echo "   The SessionStart hook re-runs this on every session, so the links"
  echo "   follow plugin updates on their own."
fi

exit "$STATUS"
