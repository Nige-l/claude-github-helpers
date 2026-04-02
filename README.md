# claude-github-helpers

Open-source GitHub issue management plugin for Claude Code agents.

List, create, close, reopen, view, comment on, and search GitHub issues — all returning structured JSON. Gives Claude Code agents reliable, parseable access to GitHub issue data without shelling out raw `gh` commands.

## Requirements

- **[gh CLI](https://cli.github.com)** — installed and authenticated (`gh auth status`)
- **[Bun](https://bun.sh)** — the MCP server runs on Bun

## Quick Start

**1. Install and authenticate the gh CLI** (if not already done):

```sh
sudo apt install -y gh        # Debian/Ubuntu
gh auth login
```

**2. Install the plugin.**

Add the GitHub repo as a marketplace, then install:

```sh
claude plugin marketplace add https://github.com/Nige-l/claude-github-helpers
claude plugin install github-helpers
```

**3. Use the tools.** Ask Claude to list issues, create a bug report, close an issue after a commit, or search for duplicates. The tools are available automatically once the plugin is installed.

### Alternative: local install from a clone

```sh
git clone https://github.com/Nige-l/claude-github-helpers.git
claude --plugin-dir ./claude-github-helpers
```

This loads the plugin for a single session without installing it globally.

## Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `list_issues` | List and filter issues | `repo`, `state` (open/closed/all), `labels`, `assignee`, `milestone`, `limit` |
| `create_issue` | Create a new issue | `repo`, `title`, `body`, `labels`, `assignee` |
| `close_issue` | Close an issue | `repo`, `number`, `comment` (optional) |
| `reopen_issue` | Reopen a closed issue | `repo`, `number`, `comment` (optional) |
| `view_issue` | View full issue + comments | `repo`, `number` |
| `add_comment` | Comment on an issue | `repo`, `number`, `body` |
| `search_issues` | Search by keyword | `repo`, `query`, `state`, `limit` |
| `batch_close` | Close multiple issues at once | `repo`, `numbers` (array), `comment` (optional) |
| `git_status` | Show working tree status | `repo` |
| `git_diff` | Show file changes | `repo`, `staged` (boolean) |
| `git_log` | Show commit history | `repo`, `limit` |
| `stage_files` | Stage files for commit | `repo`, `files` (array) |
| `create_commit` | Create a commit | `repo`, `message`, `files` (array) |
| `git_push` | Push commits to remote | `repo`, `branch`, `force` (boolean) |

All tools return structured JSON. The `repo` parameter takes `owner/repo` format (e.g. `Nige-l/WorldOfFantasyWarStuff`).

## Skills

| Skill | Description |
|-------|-------------|
| `/github-helpers:setup` | Check and install `gh` CLI, authenticate, verify access |

## Examples

**List open bugs:**
```
list_issues(repo: "owner/repo", state: "open", labels: ["bug"])
```

**Create a bug report:**
```
create_issue(repo: "owner/repo", title: "[Bug] movement rubber-banding at high latency", body: "Steps to reproduce...", labels: ["bug"])
```

**Close after a commit:**
```
close_issue(repo: "owner/repo", number: 42, comment: "Fixed in commit abc1234")
```

**Search for duplicates before filing:**
```
search_issues(repo: "owner/repo", query: "rubber-banding movement", state: "all")
```

**Add investigation notes:**
```
add_comment(repo: "owner/repo", number: 42, body: "Traced to PacketHandler.cs:87 — stale ref after entity Add")
```

## Contributing

Contributions are welcome. Open an issue or submit a pull request.

## License

[MIT](LICENSE)
