#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 1 )); then
    echo "Usage: agent_start.sh <task-slug>" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
TASK_SLUG="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/-\+/-/g; s/^-//; s/-$//')"
if [[ -z "$TASK_SLUG" ]]; then
    echo "Task slug is empty after normalization." >&2
    exit 2
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "The worktree must be clean before starting an agent task." >&2
    exit 2
fi

git -C "$REPO_ROOT" fetch origin dev
git -C "$REPO_ROOT" switch --create "agent/$TASK_SLUG" --track origin/dev
echo "Agent task branch created: agent/$TASK_SLUG"
