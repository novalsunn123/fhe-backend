#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 2 || $# > 3 )); then
    echo "Usage: agent_submit.sh <commit-message> <change-note-file> [pull-request-title]" >&2
    exit 2
fi

COMMIT_MESSAGE="$1"
CHANGE_NOTE_FILE="$2"
PR_TITLE="${3:-$COMMIT_MESSAGE}"
BASE_BRANCH="dev"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
GITHUB_AGENT_TOKEN="${GITHUB_AGENT_TOKEN:?Set GITHUB_AGENT_TOKEN to a fine-grained token before submitting}"

"$REPO_ROOT/CICD/validate_change_note.sh" "$CHANGE_NOTE_FILE"
CHANGE_NOTE_ABS="$(realpath -e -- "$CHANGE_NOTE_FILE")"
if [[ "$CHANGE_NOTE_ABS" == "$REPO_ROOT/"* ]] \
        && ! git -C "$REPO_ROOT" check-ignore -q -- "$CHANGE_NOTE_ABS"; then
    echo "A change note inside the repository must be ignored by Git; use .agent-change-note.md." >&2
    exit 2
fi
CHANGE_NOTE="$(<"$CHANGE_NOTE_FILE")"

if [[ ! "$CURRENT_BRANCH" =~ ^agent/[a-z0-9._-]+$ ]]; then
    echo "Agent submissions must use an agent/* branch; current branch: $CURRENT_BRANCH" >&2
    exit 2
fi
if [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "There are no source changes to submit." >&2
    exit 2
fi

git -C "$REPO_ROOT" add -A
staged_files="$(git -C "$REPO_ROOT" diff --cached --name-only)"
if printf '%s\n' "$staged_files" | grep -Eq \
    '(^|/)(build|keys_exp[^/]*|server_keys_exp[^/]*|ciphertexts|results|checkpoints|weights)(/|$)|(^|/)secret-key\.txt$|\.bin$'; then
    echo "Submission contains generated, sensitive, or heavyweight files:" >&2
    printf '%s\n' "$staged_files" | grep -E \
        '(^|/)(build|keys_exp[^/]*|server_keys_exp[^/]*|ciphertexts|results|checkpoints|weights)(/|$)|(^|/)secret-key\.txt$|\.bin$' >&2
    exit 3
fi
if printf '%s\n' "$staged_files" | grep -Eq '^(\.github/|CICD/|AGENTS\.md$)'; then
    echo "Agent tasks may not change trusted CI/promotion policy files." >&2
    exit 3
fi

cmake -S "$REPO_ROOT/FHEClient" -B "$REPO_ROOT/FHEClient/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local
cmake --build "$REPO_ROOT/FHEClient/build" --parallel 2
cmake -S "$REPO_ROOT/FHEServer" -B "$REPO_ROOT/FHEServer/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/local
cmake --build "$REPO_ROOT/FHEServer/build" --parallel 2

git -C "$REPO_ROOT" diff --cached --check
git -C "$REPO_ROOT" commit -m "$COMMIT_MESSAGE" -m "$CHANGE_NOTE"
git -C "$REPO_ROOT" push --set-upstream origin "$CURRENT_BRANCH"

remote_url="$(git -C "$REPO_ROOT" remote get-url origin)"
repository="$(printf '%s' "$remote_url" | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#\.git$##')"
if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
    echo "Cannot derive GitHub OWNER/REPO from origin: $remote_url" >&2
    exit 4
fi
owner="${repository%%/*}"
existing_pr="$(curl --fail-with-body --silent --show-error --get \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_AGENT_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    --data-urlencode "head=$owner:$CURRENT_BRANCH" \
    --data-urlencode "base=$BASE_BRANCH" \
    --data-urlencode "state=open" \
    "https://api.github.com/repos/$repository/pulls")"

existing_url="$(jq -r '.[0].html_url // empty' <<< "$existing_pr")"
if [[ -n "$existing_url" ]]; then
    existing_number="$(jq -er '.[0].number' <<< "$existing_pr")"
    update_payload="$(jq -n --arg title "$PR_TITLE" --arg body "$CHANGE_NOTE" \
        '{title: $title, body: $body}')"
    curl --fail-with-body --silent --show-error --location \
        --request PATCH \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_AGENT_TOKEN" \
        --header "X-GitHub-Api-Version: 2026-03-10" \
        "https://api.github.com/repos/$repository/pulls/$existing_number" \
        --data "$update_payload" >/dev/null
    echo "Existing pull request updated: $existing_url"
    exit 0
fi

payload="$(jq -n \
    --arg title "$PR_TITLE" \
    --arg head "$CURRENT_BRANCH" \
    --arg base "$BASE_BRANCH" \
    --arg body "$CHANGE_NOTE" \
    '{title: $title, head: $head, base: $base, body: $body, draft: false}')"
created_pr="$(curl --fail-with-body --silent --show-error --location \
    --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_AGENT_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "https://api.github.com/repos/$repository/pulls" \
    --data "$payload")"

echo "Pull request created: $(jq -r '.html_url' <<< "$created_pr")"
echo "The self-hosted FHE performance gate will now run automatically."
