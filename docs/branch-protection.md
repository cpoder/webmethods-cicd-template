# Branch protection on `main`

This document is the **single source of truth** for the rules that
guard the `main` branch. The rules are codified in
[`scripts/setup/branch-protection.sh`](../scripts/setup/branch-protection.sh)
so the configuration lives in version control instead of clickops:
re-running the script reconciles the live branch protection back to
what the repo describes. Changes to the policy go through the same
PR + review path as any other code change.

The script wraps two REST endpoints:

1. `PUT /repos/:o/:r/branches/main/protection` — every rule below
   except signed commits.
2. `POST /repos/:o/:r/branches/main/protection/required_signatures` —
   enables signed commits (lives behind a separate sub-resource on
   the GitHub API).

Both calls are idempotent: GitHub treats the PUT as upsert, and the
POST tolerates a re-enable. The script verifies state on `--show`.

## What the rules enforce

| Rule                            | Effect                                                                                             |
| ------------------------------- | -------------------------------------------------------------------------------------------------- |
| Pull request required           | Direct pushes to `main` are rejected; everything goes through a PR.                                |
| `>= 1` approving review         | At least one human approval before merge. CODEOWNERS bumps `/config/prod/` to **`>= 2`** (below). |
| Code owner reviews required     | Each [CODEOWNERS](../CODEOWNERS) rule that owns a changed file must approve.                       |
| Dismiss stale approvals         | New commits after an approval invalidate that approval — reviewer must re-look.                    |
| Require last-push approval      | The person who pushed the most recent commit cannot count as their own approver.                   |
| Status check `gate` required    | The aggregator job from `.github/workflows/ci.yml` must be green.                                  |
| Strict status checks            | The PR branch must be up to date with `main` before merge.                                         |
| Linear history                  | No merge commits — squash or rebase only. Keeps `git log main` linear.                             |
| Signed commits                  | Every commit on `main` must carry a verified GPG / SSH / S/MIME signature.                         |
| No force-pushes                 | `git push --force` to `main` is rejected.                                                          |
| No deletion                     | The `main` branch cannot be deleted.                                                               |
| Conversation resolution         | All PR review threads must be marked resolved before merge.                                        |
| Push restricted to release bot  | Only the configured GitHub App / user / team can push (and only via merge — direct push is still PR-gated). |
| Enforce on admins               | Repo admins are also subject to all of the above. No bypass.                                       |

### How `>= 2` approvals on `/config/prod/` works

GitHub does not expose "require N approvals on path X" as a single
field. The canonical way to express it is via CODEOWNERS:

```
# CODEOWNERS
/config/prod/ @devops-team @release-managers
```

When `required_pull_request_reviews.require_code_owner_reviews` is
`true` (which this script sets), every distinct CODEOWNERS rule that
owns at least one changed file must contribute at least one approval.
Listing two teams on the `/config/prod/` line therefore demands one
approval from each — effectively `>= 2` approvals on any PR that
touches that path, while leaving the global minimum at `1` for the
rest of the repo.

The `required_approving_review_count` field is the **floor** across
the whole repo; it is not "per rule". Path-specific minimums are
expressed structurally through CODEOWNERS rule splitting.

### How `gate` ties into this

`.github/workflows/ci.yml` defines a job named `gate` whose only
purpose is to aggregate every other CI job's `result`. That single
status check is what branch protection requires. To add a new check
to the gate, extend `gate.needs` and the `toJson(needs)` walk in
that workflow — branch protection does not need to be touched. See
the orchestrator notes in `.github/workflows/ci.yml` (Task 6.1).

### Restrict who can push to `main`

The `restrictions` block on the protection endpoint accepts three
arrays — `users`, `teams`, `apps` — of principals allowed to push.
The release bot lives in the `apps` array (it is a GitHub App with
`contents:write`). Direct `git push origin main` is **still**
rejected for everyone, including the bot, because the PR-required
rule applies first; the bot can only push the squash/rebase merge
commit produced by an approved PR. The restriction is a defence in
depth, not the primary gate.

The script refuses to apply without at least one of `--bot-app`,
`--bot-user`, or `--bot-team` (or an explicit
`--no-restrict-pushers` opt-out), because the GitHub API itself
rejects an empty restriction with HTTP 422.

## Bootstrap procedure

The script is meant to run **once** by a repo admin (only admins can
edit branch protection) and then re-run only when the policy changes.
It needs `gh` (logged in with admin scope on the repo) and `jq`.

### Dry-run

```sh
scripts/setup/branch-protection.sh
```

Prints the JSON body it would PUT plus a note about the signed-commits
sub-call. Does not require `gh auth` (uses `<owner>/<repo>` placeholder
when no remote is configured).

### Apply (admin only)

```sh
scripts/setup/branch-protection.sh \
    --apply \
    --bot-app release-bot
```

The script PUTs the protection body, then POSTs the
`required_signatures` sub-resource. Both calls are idempotent.

Restrict to multiple principals:

```sh
scripts/setup/branch-protection.sh \
    --apply \
    --bot-app release-bot \
    --bot-team release-managers \
    --bot-user wm-deploy-bot
```

Tune the gate name or branch:

```sh
scripts/setup/branch-protection.sh \
    --apply \
    --branch main \
    --gate-check gate \
    --bot-app release-bot
```

### Inspect current state

```sh
scripts/setup/branch-protection.sh --show
```

Prints the current protection JSON plus the
`required_signatures.enabled` flag.

### Tear down (rare)

```sh
scripts/setup/branch-protection.sh --remove
```

DELETEs the protection. Only useful for re-bootstrapping or
emergency unblocks.

## Acceptance criteria

The task spec for 6.2 requires:

1. **Idempotent script.** Re-running `--apply` with the same modifiers
   produces no observable change. GitHub's `PUT
   /branches/:b/protection` is upsert; the
   `required_signatures` POST tolerates re-enable. The script does
   not store local state and re-derives everything from CLI args /
   env. No tempfiles; no surprise mutations.

2. **`gh api repos/:o/:r/branches/main/protection` reflects the
   rules.** Verifiable via `--show`, or directly:

   ```sh
   gh api repos/<owner>/<repo>/branches/main/protection | jq .
   ```

   Expected fields:

   - `required_status_checks.strict == true`
   - `required_status_checks.contexts == ["gate"]`
   - `required_pull_request_reviews.required_approving_review_count == 1`
   - `required_pull_request_reviews.dismiss_stale_reviews == true`
   - `required_pull_request_reviews.require_code_owner_reviews == true`
   - `required_pull_request_reviews.require_last_push_approval == true`
   - `required_linear_history.enabled == true`
   - `allow_force_pushes.enabled == false`
   - `allow_deletions.enabled == false`
   - `enforce_admins.enabled == true`
   - `restrictions.apps[*].slug` includes the release bot

   And separately:

   ```sh
   gh api repos/<owner>/<repo>/branches/main/protection/required_signatures \
       --jq .enabled
   # => true
   ```

3. **A PR without a green `gate` cannot be merged.** This falls out
   of `required_status_checks.contexts == ["gate"]`. To verify
   manually after bootstrap:

   1. Open a PR that intentionally fails the orchestrator (e.g.
      break a test or push a malformed manifest).
   2. Wait for the `gate` job to fail.
   3. Click "Merge pull request" — GitHub must show "Required
      statuses must pass" and the merge button must be disabled.
   4. Fix the failure, push again, wait for `gate` to go green —
      merge unblocks (subject to the approval / signed-commit /
      conversation-resolution rules).

## Related

- [`CODEOWNERS`](../CODEOWNERS) — the path-to-team mapping that
  drives the implicit `>= 2` for `/config/prod/`.
- [`scripts/setup-environments.sh`](../scripts/setup-environments.sh)
  — sibling bootstrap for GitHub Environments + secrets (Task 3.3).
  Same shape, same idempotency contract.
- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) —
  defines the `gate` aggregator job that this protection requires
  (Task 6.1).
- [`docs/secrets.md`](secrets.md) — the prod environment also has
  its own protection (required reviewers + wait timer); branch
  protection on `main` and Environment protection on `prod` are
  complementary, not redundant.
