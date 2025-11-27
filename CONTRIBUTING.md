# Contributing

Thank you for contributing. This document explains the repository workflow, PR expectations, and the manual promotion checklist used to update the conservative `stable` branch.

## Branching model
- `stable-style` — Working & deploy branch. All active development and verification (UI/UX and functional changes) happens here. Deploys should be tested from this branch.
- `stable` — Conservative, validated backup. Only updated manually after full validation. Do NOT automate pushes from `stable-style` into `stable`.

## Pull requests & commits
- Open a pull request from a feature branch into `stable-style` (or push directly to `stable-style` if your team policy allows). Keep PRs small and focused.
- Include a clear description of what changed and any manual steps needed to verify behavior.
- Tag reviewers and request a code review; fixes or follow-up commits should be pushed to the same branch/PR.

## Tests & quality checks
- Run existing tests (if present) and smoke the app locally before pushing.
- Run `bundle install` and `bundle exec rake db:migrate` locally when migrations are included in the PR.

## Promotion Checklist (must pass before updating `stable`)
Run these manual checks after a successful deploy from `stable-style` and before updating `stable`.

- Health & logs
  - Confirm `/health` returns HTTP 200.
  - Check deploy logs for migration success and absence of startup errors.

- Authentication
  - Log in as super-admin, semi-admin, and regular user; verify session, logout, and password flows.

- Core workflows
  - Create and view equipment entries.
  - Create, approve, and return requests; verify deployed counts update.
  - Create a deployed `UserEquipment` as semi-admin, edit as owner and ensure non-owners are blocked.

- Scanner & mobile flows
  - Test scanner flows and guided per-unit scanning in supported browsers.

- UI & responsiveness
  - Verify key pages on desktop and mobile widths (Dashboard, Inventory, Requests, Deploy, Settings).

- Exports & backups
  - Run the export flow and confirm a JSON export is created (and uploaded if configured).

- Edge/error handling
  - Trigger a graceful error path and verify the app handles it without exposing secrets.

- Logs & metrics
  - Tail logs while exercising functionality to catch runtime exceptions.

## How to update `stable` (manual)
Prefer the PR/merge path for auditability:

```powershell
git checkout stable
git merge --no-ff stable-style
git push origin stable
```

If you must fast-forward `stable` in one step (explicit manual action only):

```powershell
# Manual one-step: only run when 100% confident
git push origin stable-style:stable
```

## Need help?
If you want a formal checklist converted into CI smoke tests or a GitHub Action that runs checks after deploy (without auto-updating `stable`), I can help create that.

Thank you — keep `stable` conservative and intentional.
