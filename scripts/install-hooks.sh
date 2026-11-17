#!/usr/bin/env bash
# Point this clone's git hooks at scripts/hooks (once per clone; worktrees share it).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git config core.hooksPath scripts/hooks
echo "hooks: $(git config core.hooksPath)"
