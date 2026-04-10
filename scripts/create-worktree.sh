#!/usr/bin/env bash
# Creates an isolated git worktree for a task branch.
# Each task gets its own directory under worktrees/.
# Usage: ./scripts/create-worktree.sh <task-id>
# Prints the worktree directory path on stdout.
set -euo pipefail

TASK_ID="$1"
BRANCH="agent/${TASK_ID}"
DIR="worktrees/${TASK_ID}"

if [ ! -d "$DIR" ]; then
  git worktree add -b "$BRANCH" "$DIR"
fi

# Symlink .ai/state and .ai/handoffs so queue writes stay canonical
for LINK in .ai/state .ai/handoffs .ai/tasks; do
  TARGET="${DIR}/${LINK}"
  if [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then
    rm -rf "$TARGET"
  fi
  if [ ! -L "$TARGET" ]; then
    mkdir -p "${DIR}/$(dirname ${LINK})"
    ln -s "$(pwd)/${LINK}" "$TARGET"
  fi
done

echo "$DIR"
