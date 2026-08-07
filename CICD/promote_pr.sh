#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 10 )); then
    echo "Usage: promote_pr.sh <repo> <pr-number> <head-sha> <base-sha> <candidate.json> <comparison.json> <title-file> <body-file> <readme-entry.md> <baseline-state.json>" >&2
    exit 2
fi

REPOSITORY="$1"
PR_NUMBER="$2"
HEAD_SHA="$3"
BASE_SHA="$4"
CANDIDATE_JSON="$5"
COMPARISON_JSON="$6"
TITLE_FILE="$7"
BODY_FILE="$8"
README_ENTRY_FILE="$9"
BASELINE_STATE="${10}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required for PR promotion}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

for file in "$CANDIDATE_JSON" "$COMPARISON_JSON" "$TITLE_FILE" "$BODY_FILE" "$README_ENTRY_FILE"; do
    if [[ ! -s "$file" ]]; then
        echo "Missing promotion input: $file" >&2
        exit 2
    fi
done

if [[ "$(jq -r '.status' "$CANDIDATE_JSON")" != "passed" ]]; then
    echo "Candidate benchmark did not pass." >&2
    exit 3
fi
if [[ "$(jq -r '.verdict' "$COMPARISON_JSON")" != "auto_merge" ]]; then
    echo "Comparison is not eligible for automatic promotion." >&2
    exit 3
fi
if [[ "$(jq -r '.commit' "$CANDIDATE_JSON")" != "$HEAD_SHA" ]]; then
    echo "Candidate benchmark SHA does not match the current PR head." >&2
    exit 3
fi
if [[ "$(jq -r '.candidate_commit' "$COMPARISON_JSON")" != "$HEAD_SHA" ]]; then
    echo "Comparison SHA does not match the current PR head." >&2
    exit 3
fi
if [[ ! -s "$BASELINE_STATE" || "$(jq -r '.commit' "$BASELINE_STATE")" != "$BASE_SHA" ]]; then
    echo "The dev baseline changed after this candidate was benchmarked; refusing stale promotion." >&2
    exit 3
fi

commit_title="$(tr '\r\n' ' ' < "$TITLE_FILE" | sed 's/[[:space:]]\+/ /g; s/[[:space:]]*$//')"
commit_body="$(<"$BODY_FILE")"
if [[ -z "$commit_title" ]]; then
    echo "Generated commit title is empty." >&2
    exit 3
fi

payload_file="$(mktemp /tmp/fhe-promotion-payload.XXXXXX.json)"
response_file="$(mktemp /tmp/fhe-promotion-response.XXXXXX.json)"
readme_response="$(mktemp /tmp/fhe-readme-response.XXXXXX.json)"
readme_current="$(mktemp /tmp/fhe-readme-current.XXXXXX.md)"
readme_updated="$(mktemp /tmp/fhe-readme-updated.XXXXXX.md)"
readme_payload="$(mktemp /tmp/fhe-readme-payload.XXXXXX.json)"
trap 'rm -f -- "$payload_file" "$response_file" "$readme_response" "$readme_current" "$readme_updated" "$readme_payload"' EXIT

jq -n \
    --arg title "$commit_title" \
    --arg message "$commit_body" \
    --arg sha "$HEAD_SHA" \
    '{commit_title: $title, commit_message: $message, sha: $sha, merge_method: "squash"}' \
    > "$payload_file"

curl --fail-with-body --silent --show-error --location \
    --request PUT \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "$GITHUB_API_URL/repos/$REPOSITORY/pulls/$PR_NUMBER/merge" \
    --data-binary "@$payload_file" > "$response_file"

if [[ "$(jq -r '.merged // false' "$response_file")" != "true" ]]; then
    echo "GitHub did not merge the pull request:" >&2
    jq -r '.message // "unknown response"' "$response_file" >&2
    exit 4
fi

merge_sha="$(jq -er '.sha' "$response_file")"

curl --fail-with-body --silent --show-error --location \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "$GITHUB_API_URL/repos/$REPOSITORY/git/ref/heads/dev" \
    > "$readme_response"
dev_head_sha="$(jq -er '.object.sha' "$readme_response")"
if [[ "$dev_head_sha" != "$merge_sha" ]]; then
    echo "dev advanced unexpectedly after merge; refusing to write README history." >&2
    exit 4
fi

curl --fail-with-body --silent --show-error --location \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "$GITHUB_API_URL/repos/$REPOSITORY/contents/README.md?ref=$merge_sha" \
    > "$readme_response"

readme_blob_sha="$(jq -er '.sha' "$readme_response")"
jq -er '.content' "$readme_response" | tr -d '\n' | base64 --decode > "$readme_current"
"$(dirname -- "$0")/update_readme_history.sh" \
    "$readme_current" "$README_ENTRY_FILE" "$readme_updated" \
    "$REPOSITORY" "$merge_sha" "$commit_title"

readme_content="$(base64 -w 0 "$readme_updated")"
jq -n \
    --arg message "docs: record dev benchmark ${merge_sha:0:7}" \
    --arg content "$readme_content" \
    --arg sha "$readme_blob_sha" \
    '{message: $message, content: $content, sha: $sha, branch: "dev"}' \
    > "$readme_payload"

curl --fail-with-body --silent --show-error --location \
    --request PUT \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "X-GitHub-Api-Version: 2026-03-10" \
    "$GITHUB_API_URL/repos/$REPOSITORY/contents/README.md" \
    --data-binary "@$readme_payload" > "$readme_response"

documentation_sha="$(jq -er '.commit.sha' "$readme_response")"
mkdir -p "$(dirname -- "$BASELINE_STATE")"
baseline_tmp="${BASELINE_STATE}.tmp.$$"
jq \
    --arg documentation_sha "$documentation_sha" \
    --arg code_sha "$merge_sha" \
    --arg title "$commit_title" \
    --arg candidate_sha "$HEAD_SHA" \
    '.commit = $documentation_sha
     | .code_commit = $code_sha
     | .documentation_commit = $documentation_sha
     | .branch = "dev"
     | .commit_subject = $title
     | .promoted_from_candidate = $candidate_sha
     | .promoted_at = (now | todateiso8601)' \
    "$CANDIDATE_JSON" > "$baseline_tmp"
mv -f -- "$baseline_tmp" "$BASELINE_STATE"

echo "Pull request #$PR_NUMBER promoted to dev as code commit $merge_sha"
echo "README version history recorded in $documentation_sha"
echo "Baseline updated: $BASELINE_STATE"
