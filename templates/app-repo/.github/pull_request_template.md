<!-- Title: <TICKET-ID>: <what changed>   e.g. PROJ-214: Add OTP login
     PRs into main also need the release version: REL-12: release v2.4.0 -->

## What and why

## How it was tested

## Checklist
- [ ] Branch name follows the playbook (`feature/`, `bugfix/`, `hotfix/<TICKET>-<slug>`, `release/X.Y.Z`)
- [ ] Target branch is the next stage (feature/bugfix -> `develop`; hotfix -> `main`)
- [ ] Database changes are backward compatible (expand/contract) - a rollback does not undo migrations
- [ ] Merge method: **Squash** for feature/bugfix into `develop`; **Create a merge commit** for every promotion, release and hotfix
