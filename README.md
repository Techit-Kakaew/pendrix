# Pendrix

One window for the things that need you: Jira tasks assigned to you, GitLab merge requests waiting on your review, mentions and todos. Polls in the background, pings when something new lands, lives in the menu bar with a count.

macOS 26 uses Liquid Glass; older macOS falls back to thin material.

## Build

```bash
./build.sh            # dist/Pendrix.app
./build.sh --install  # copy to /Applications and launch
./build.sh --dmg      # universal dmg + sha256 in dist/
```

## Launch at login & updates

Settings → General: Launch at login (SMAppService), automatic update checks (every 6 h against the GitHub releases of the configured `owner/repo`), Check now, Update now. The updater downloads the release `.dmg`, verifies it against the `.dmg.sha256` asset, swaps the bundle in place keeping its signature, and relaunches.

Publishing a release:

```bash
scripts/release.sh 0.2.0 "what changed"
```

## Setup

Open Pendrix → Settings (⌘,).

- **Jira Cloud**: site (`acme.atlassian.net`), email, API token from https://id.atlassian.com/manage-profile/security/api-tokens. JQL is editable; default is `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`.
- **GitLab / GitHub**: any number of accounts. GitLab token: `api` (review actions) or `read_api` (inbox only). GitHub token: classic `repo`, or fine-grained with Pull requests read/write.

Review requests you have already approved (GitHub: reviewed) move to "Approved by you · waiting to merge" and stop counting as waiting on you.

## Inbox filters, keyboard, overdue

Filter (⌘F) or Settings → Inbox: hide drafts, hide bot authors, group by repo, only projects/repos matching a list. Keyboard: j / k or arrows move, Enter opens, `a` approves the selected review request (Touch ID). Review requests older than N hours (default 24) get a red "waiting" pill, turn the card red, count as "overdue" in the header and notify once.

## Jira from the app

Right-click a Jira row: move to any available status, comment, assign to me. MRs/PRs whose title or branch mention a Jira key (PAY-412) show that issue as a chip, and the issue shows its MRs.

## Standup (parked)

Built but hidden behind `Features.standup` (Sources/Pendrix/Features.swift). Yesterday / Today / Blockers from Jira changelog + GitLab/GitHub events, optional Claude or on-device spoken version in Thai/English. Flip the flag to bring it back.

## Review in-app

Click an MR/PR → review screen in the same window (Back / Esc returns): file list, unified diff, threads under their lines. Header shows files / +− / commit count. The sidebar lists commits; click one to browse just that commit's files (read-only, comments stay on the whole change), "All changes" returns. Syntax highlighting by file extension (Highlightr). Click a line number to comment on it. Reply / Resolve per thread, Approve, Merge (confirmed). GitHub un-approve is web-only.

Tokens go to Keychain. Everything else in UserDefaults.

## Security

Tokens live in the login Keychain (ACL: Pendrix only). Settings and write actions (approve, merge, comment, resolve) require Touch ID or the account password; one unlock covers 5 minutes. Toggle under Settings → Security. Lock the screen when you step away — that is the real defence.

## Debug

```bash
.build/debug/Pendrix --snapshot out.png          # dashboard with demo data
.build/debug/Pendrix --snapshot out.png --menu   # menu-bar panel
.build/debug/Pendrix --snapshot out.png --light
.build/debug/Pendrix --snapshot out.png --review  # review window
```

## Code signing (one-time)

Ad-hoc signatures change on every build, so macOS re-asks Keychain permission for the stored tokens each time. Use a local self-signed identity instead:

```bash
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /path/to/pendrix-dev.crt
```

Then `./build.sh` picks up "Pendrix Dev" automatically. First sign prompts once for key access → Always Allow.
