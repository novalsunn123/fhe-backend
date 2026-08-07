# Agent contribution policy

Agent-authored changes must start from the latest `origin/dev` on a branch
named `agent/<task-slug>`. Never commit directly to `dev` or `main`.

Agents may change application source, headers, CMake configuration, tests, and
documentation requested by the user. They must not modify `.github/`, `CICD/`,
or this policy as part of an ordinary source task. Changes to benchmark and
promotion policy require an explicit maintenance task and manual bootstrap on
`dev`.

Never stage or commit FHE keys, secret keys, model weights, ciphertexts,
encrypted results, checkpoints, build output, logs, PID files, core dumps, or
other generated binary artifacts.

Before submission, configure and build both `FHEClient` and `FHEServer` in
Release mode, inspect the staged diff, and run `git diff --cached --check`.
Use `CICD/agent_start.sh` to create the task branch and
`CICD/agent_submit.sh` to validate, commit, push, and open the pull request.
Every submission must provide a change-note Markdown file with the exact
headings `## Đã sửa gì`, `## Cơ chế`, `## Cách hoạt động`, and
`## Lợi ích`. Write concrete behavior and user impact under every heading;
this note becomes the permanent dev-version entry only after promotion.

The candidate must pass the trusted FHE performance gate against the most
recent successful `dev` baseline. Only the promotion job may squash-merge an
eligible pull request. A rejected or incomparable candidate remains outside
`dev`; never bypass the gate with a force push.
