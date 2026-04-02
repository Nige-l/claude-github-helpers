---
name: setup
description: Check and install the gh CLI, authenticate with GitHub, and verify issue access. Use when user asks to set up the plugin, or when tools fail with auth or missing-dependency errors.
user-invocable: true
allowed-tools: [Bash, Read]
---

# /github-helpers:setup

Guide the user through installing and authenticating the GitHub CLI for the github-helpers plugin.

## Steps

### 1. Check if gh is installed

```bash
command -v gh && gh --version
```

- If found: proceed to step 2.
- If missing: proceed to step 3 to install it.

### 2. Check authentication status

```bash
gh auth status
```

- If authenticated (no error): proceed to step 4.
- If not authenticated (`You are not logged into any GitHub hosts`): proceed to step 3b.
- If token expired or invalid: proceed to step 3b.

### 3. Install or re-authenticate

**3a. Install gh CLI (if missing)**

Check which package manager is available and install:

| Distro | Check | Install command |
|--------|-------|----------------|
| Debian/Ubuntu | `command -v apt` | `sudo apt update && sudo apt install -y gh` |
| Fedora | `command -v dnf` | `sudo dnf install -y gh` |
| Arch | `command -v pacman` | `sudo pacman -S --noconfirm github-cli` |
| openSUSE | `command -v zypper` | `sudo zypper install -y gh` |

Tell the user the exact command and ask for confirmation before running it (requires sudo).

After install, verify:
```bash
gh --version
```

**3b. Authenticate**

Explain to the user that authentication requires an interactive login and ask them to run this command in their terminal:

```
gh auth login
```

Select GitHub.com, HTTPS, and authenticate via browser or token. After they confirm it completed, re-run the auth check:

```bash
gh auth status
```

### 4. Verify issue access

Run a quick test against a known public repo to confirm tools are working:

```bash
gh issue list --repo cli/cli --limit 3 --json number,title,state
```

- If this returns JSON: setup is complete. Report success.
- If it returns an error: diagnose based on the error message (auth, network, rate limit) and guide the user accordingly.

Suggest asking Claude to try `list_issues` on their own repo as a final smoke test.
