# GitHub Helpers Plugin

Structured GitHub issue management for Claude Code agents. You have 7 tools for listing, creating, closing, reopening, viewing, commenting on, and searching issues.

## Tool quick reference

| Tool | Purpose |
|------|---------|
| `list_issues` | List and filter open/closed issues by label, assignee, milestone |
| `create_issue` | Create a new issue with title, body, labels, and assignee |
| `close_issue` | Close an issue, optionally leaving a comment |
| `reopen_issue` | Reopen a closed issue, optionally leaving a comment |
| `view_issue` | View full issue details including all comments |
| `add_comment` | Add a comment to an existing issue |
| `search_issues` | Search issues by keyword across title and body |

## Repo parameter

Always pass the full `owner/repo` string — e.g. `Nige-l/WorldOfFantasyWarStuff`. Never use a short name or omit the owner.

## Decision tree — which tool to use

**Finding work:**
1. `list_issues` — browse open issues; filter by label (e.g. `bug`) or assignee
2. `view_issue` — read full details including comments before acting

**Filing a bug or feature:**
1. `search_issues` first — avoid duplicates
2. If no match: `create_issue` with title, body, and appropriate labels

**Closing work after a commit:**
1. `close_issue` with a comment referencing the commit SHA or PR number
2. Do NOT close without a comment — the comment creates a paper trail

**Triage loop:**
1. `list_issues` to get the backlog
2. `view_issue` on each relevant item for full context
3. `add_comment` to record investigation findings
4. `close_issue` if already fixed, or leave open with updated comment

**Searching:**
- `search_issues` with a keyword to find related issues before creating a new one
- Default state is `open` — pass `state: "all"` explicitly to include closed issues

## Common patterns

**Create a bug report:**
```
create_issue(
  repo: "owner/repo",
  title: "[Bug] short description",
  body: "Steps to reproduce...\n\nExpected: ...\nActual: ...",
  labels: "bug"
)
```

**Close after commit:**
```
close_issue(
  repo: "owner/repo",
  number: 42,
  comment: "Fixed in commit abc1234 — root cause was ..."
)
```

**Claim an issue (self-assignment):**
```
add_comment(repo: "owner/repo", number: 42, body: "Claiming — coder-1")
```

**Check for duplicates before filing:**
```
search_issues(repo: "owner/repo", query: "movement rubber-banding", state: "all")
```

**Add investigation notes:**
```
add_comment(repo: "owner/repo", number: 42, body: "Explorer: traced to PacketHandler.cs:87 — stale ref after entity Add")
```

## Preferred workflow

1. `list_issues` — understand the backlog
2. `view_issue` — read full context on the issue you're about to touch
3. Act: `create_issue`, `close_issue`, `add_comment`, etc.
4. Always leave a comment when closing — explain what fixed it

## Error handling

- **Tool returns error / non-zero exit:** Log what failed and report to orchestrator. Do NOT silently continue.
- **`gh` auth expired:** The tool will surface a `gh auth status` error. Ask the user to run `gh auth login` or suggest `/github-helpers:setup`.
- **Rate limit hit:** Wait and retry once. If it persists, report back — do not loop.
- **Issue not found:** Verify the issue number and repo. Do not create a duplicate.
- **Permission denied:** You may not have write access to the repo. Report back rather than retrying.

## Dependencies

- **`gh` CLI** — installed and authenticated. If tools fail, suggest running `/github-helpers:setup`.
- **`python3`** — required for JSON transformation in the shell layer. Available by default on most Linux distros.
