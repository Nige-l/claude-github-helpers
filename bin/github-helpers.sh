#!/usr/bin/env bash
# github-helpers.sh — Structured JSON GitHub issue management for Claude Code agents
# Called by server.ts with: $1=tool_name, remaining args as --param value pairs
set -euo pipefail

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\013'/}"    # strip vertical tab (0x0B)
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\016-\037')
    printf '%s' "$s"
}

# Print a JSON error object and exit the whole process.
# IMPORTANT: call directly (not inside $()) so exit terminates the main shell.
json_error() {
    local msg="$1" exit_code="${2:-1}" stderr="${3:-}"
    printf '{"error":"%s","exit_code":%d,"stderr":"%s"}\n' \
        "$(json_str "$msg")" "$exit_code" "$(json_str "$stderr")"
    exit 1
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

check_gh() {
    if ! command -v gh &>/dev/null; then
        json_error "gh CLI not found — install from https://cli.github.com/" 127
    fi
    if ! command -v python3 &>/dev/null; then
        json_error "python3 not found — required for JSON transformation" 127
    fi
    local auth_status
    if ! auth_status=$(gh auth status 2>&1); then
        json_error "gh CLI not authenticated: $auth_status" 1 "$auth_status"
    fi
}

# ---------------------------------------------------------------------------
# Argument parser
# Parses --param value pairs into global associative array OPTS.
#
# IMPORTANT calling convention for required params:
#   Use require_opt as a plain statement (not inside $()) so that json_error
#   can exit the main shell. Access the value via ${OPTS[key]} afterwards:
#
#     require_opt "repo"
#     local repo="${OPTS[repo]}"
#
# opt() is safe inside $() because it never calls exit.
# ---------------------------------------------------------------------------

declare -A OPTS

parse_named_args() {
    OPTS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*)
                local key="${1#--}"
                if [[ $# -gt 1 && "$2" != --* ]]; then
                    OPTS["$key"]="$2"
                    shift 2
                else
                    OPTS["$key"]=""
                    shift
                fi
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Returns value or default. Safe in $() — never exits.
opt() {
    local key="$1" default="${2:-}"
    printf '%s' "${OPTS[$key]:-$default}"
}

# Validates that a required param is present.
# MUST be called as a plain statement, NOT inside $().
require_opt() {
    local key="$1"
    if [[ -z "${OPTS[$key]:-}" ]]; then
        json_error "Missing required parameter: --$key" 1
    fi
}

# Validates that $1 is a positive integer — prevents JSON injection via
# unvalidated user input in printf %s slots.
# MUST be called as a plain statement, NOT inside $().
validate_number() {
    local val="$1"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        json_error "Invalid issue number: '$val' — must be a positive integer" 1
    fi
}

# ---------------------------------------------------------------------------
# body_args <body_var> <cmd_array_name>
# Appends either --body or --body-file to the named array depending on size.
# For bodies > 50000 chars, writes to a temp file to avoid ARG_MAX limits.
# Caller is responsible for calling cleanup_body_file afterwards.
# ---------------------------------------------------------------------------

BODY_TEMP_FILE=""

body_args() {
    local body="$1"
    local -n _cmd_ref="$2"
    BODY_TEMP_FILE=""
    if (( ${#body} > 50000 )); then
        BODY_TEMP_FILE=$(mktemp)
        printf '%s' "$body" > "$BODY_TEMP_FILE"
        _cmd_ref+=(--body-file "$BODY_TEMP_FILE")
    else
        _cmd_ref+=(--body "$body")
    fi
}

cleanup_body_file() {
    if [[ -n "$BODY_TEMP_FILE" ]]; then
        rm -f "$BODY_TEMP_FILE"
        BODY_TEMP_FILE=""
    fi
    return 0
}

# ---------------------------------------------------------------------------
# tool: list_issues
# ---------------------------------------------------------------------------

tool_list_issues() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    local state
    state=$(opt "state" "open")
    local labels
    labels=$(opt "labels" "")
    local limit
    limit=$(opt "limit" "30")
    local assignee
    assignee=$(opt "assignee" "")
    local milestone
    milestone=$(opt "milestone" "")

    check_gh

    local cmd=(gh issue list -R "$repo" --state "$state" -L "$limit"
        --json "number,title,state,labels,assignees,createdAt,updatedAt,url")

    [[ -n "$labels" ]] && cmd+=(--label "$labels")
    [[ -n "$assignee" ]] && cmd+=(--assignee "$assignee")
    [[ -n "$milestone" ]] && cmd+=(--milestone "$milestone")

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$("${cmd[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "gh issue list failed" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    python3 - "$raw" <<'PYEOF'
import sys, json

try:
    issues = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({"error": f"Failed to parse gh output: {e}", "exit_code": 1, "stderr": ""}))
    sys.exit(0)

out = []
for iss in issues:
    assignees = iss.get("assignees") or []
    assignee_login = assignees[0]["login"] if assignees else None
    out.append({
        "number": iss.get("number"),
        "title": iss.get("title", ""),
        "state": iss.get("state", ""),
        "labels": [l["name"] for l in (iss.get("labels") or [])],
        "assignee": assignee_login,
        "created_at": iss.get("createdAt", ""),
        "updated_at": iss.get("updatedAt", ""),
        "url": iss.get("url", ""),
    })

print(json.dumps({"issues": out, "total_count": len(out)}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: create_issue
# ---------------------------------------------------------------------------

tool_create_issue() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "title"
    local title="${OPTS[title]}"
    local body
    body=$(opt "body" "")
    local labels
    labels=$(opt "labels" "")
    local assignee
    assignee=$(opt "assignee" "")

    check_gh

    local cmd=(gh issue create -R "$repo" --title "$title")
    body_args "$body" cmd
    [[ -n "$labels" ]] && cmd+=(--label "$labels")
    [[ -n "$assignee" ]] && cmd+=(--assignee "$assignee")

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$("${cmd[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        cleanup_body_file
        # Retry without labels if label-not-found error
        if printf '%s' "$stderr_content" | grep -qi 'could not add label'; then
            local cmd_no_labels=(gh issue create -R "$repo" --title "$title")
            body_args "$body" cmd_no_labels
            [[ -n "$assignee" ]] && cmd_no_labels+=(--assignee "$assignee")
            local stderr_file2
            stderr_file2=$(mktemp)
            if ! raw=$("${cmd_no_labels[@]}" 2>"$stderr_file2"); then
                local stderr_content2
                stderr_content2=$(cat "$stderr_file2")
                rm -f "$stderr_file2"
                cleanup_body_file
                json_error "gh issue create failed (even without labels)" 1 "$stderr_content2"
            fi
            rm -f "$stderr_file2"
            cleanup_body_file
            labels=""
        else
            json_error "gh issue create failed" 1 "$stderr_content"
        fi
    else
        rm -f "$stderr_file"
        cleanup_body_file
    fi

    # raw is the URL of the created issue
    local issue_url="$raw"
    local issue_num
    issue_num=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || printf '0')

    python3 - "$issue_num" "$issue_url" "$title" "$labels" <<'PYEOF'
import sys, json
number = int(sys.argv[1]) if sys.argv[1].isdigit() else 0
url = sys.argv[2]
title = sys.argv[3]
labels_str = sys.argv[4]
labels = [l.strip() for l in labels_str.split(",") if l.strip()] if labels_str else []
print(json.dumps({"number": number, "title": title, "url": url, "labels": labels}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: close_issue
# ---------------------------------------------------------------------------

tool_close_issue() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "number"
    local number="${OPTS[number]}"
    validate_number "$number"
    local comment
    comment=$(opt "comment" "")

    check_gh

    local cmd=(gh issue close "$number" -R "$repo")
    [[ -n "$comment" ]] && cmd+=(--comment "$comment")

    local stderr_file
    stderr_file=$(mktemp)
    if ! "${cmd[@]}" >/dev/null 2>"$stderr_file"; then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "gh issue close failed for #$number" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    local comment_added
    [[ -n "$comment" ]] && comment_added="true" || comment_added="false"
    printf '{"number":%s,"state":"closed","comment_added":%s}\n' "$number" "$comment_added"
}

# ---------------------------------------------------------------------------
# tool: reopen_issue
# ---------------------------------------------------------------------------

tool_reopen_issue() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "number"
    local number="${OPTS[number]}"
    validate_number "$number"
    local comment
    comment=$(opt "comment" "")

    check_gh

    local cmd=(gh issue reopen "$number" -R "$repo")
    [[ -n "$comment" ]] && cmd+=(--comment "$comment")

    local stderr_file
    stderr_file=$(mktemp)
    if ! "${cmd[@]}" >/dev/null 2>"$stderr_file"; then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "gh issue reopen failed for #$number" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    local comment_added
    [[ -n "$comment" ]] && comment_added="true" || comment_added="false"
    printf '{"number":%s,"state":"open","comment_added":%s}\n' "$number" "$comment_added"
}

# ---------------------------------------------------------------------------
# tool: view_issue
# ---------------------------------------------------------------------------

tool_view_issue() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "number"
    local number="${OPTS[number]}"
    validate_number "$number"

    check_gh

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$(gh issue view "$number" -R "$repo" \
        --json "number,title,state,body,labels,assignees,author,createdAt,updatedAt,comments,url" \
        2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "gh issue view failed for #$number" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    python3 - "$raw" <<'PYEOF'
import sys, json

try:
    iss = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({"error": f"Failed to parse gh output: {e}", "exit_code": 1, "stderr": ""}))
    sys.exit(0)

assignees = iss.get("assignees") or []
assignee_login = assignees[0]["login"] if assignees else None
author = iss.get("author") or {}

comments_raw = iss.get("comments") or []
comments = []
for c in comments_raw:
    comments.append({
        "author": (c.get("author") or {}).get("login", ""),
        "body": c.get("body", ""),
        "created_at": c.get("createdAt", ""),
    })

print(json.dumps({
    "number": iss.get("number"),
    "title": iss.get("title", ""),
    "state": iss.get("state", ""),
    "body": iss.get("body", "") or "",
    "labels": [l["name"] for l in (iss.get("labels") or [])],
    "assignee": assignee_login,
    "author": author.get("login", ""),
    "created_at": iss.get("createdAt", ""),
    "updated_at": iss.get("updatedAt", ""),
    "comments_count": len(comments_raw),
    "url": iss.get("url", ""),
    "comments": comments,
}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: add_comment
# ---------------------------------------------------------------------------

tool_add_comment() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "number"
    local number="${OPTS[number]}"
    validate_number "$number"
    require_opt "body"
    local body="${OPTS[body]}"

    check_gh

    local cmd=(gh issue comment "$number" -R "$repo")
    # Note: gh issue comment uses -b/--body, not --body-file; use body_args
    # which falls back to --body-file for large bodies.
    body_args "$body" cmd

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$("${cmd[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        cleanup_body_file
        json_error "gh issue comment failed for #$number" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"
    cleanup_body_file

    local comment_url="$raw"
    printf '{"number":%s,"comment_url":"%s"}\n' "$number" "$(json_str "$comment_url")"
}

# ---------------------------------------------------------------------------
# tool: batch_close
# ---------------------------------------------------------------------------

tool_batch_close() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "numbers"
    local numbers_raw="${OPTS[numbers]}"
    local comment
    comment=$(opt "comment" "")

    check_gh

    # Split comma-separated numbers into an array
    IFS=',' read -ra number_list <<< "$numbers_raw"

    local closed_arr=()
    local failed_arr=()
    local comment_added
    [[ -n "$comment" ]] && comment_added="true" || comment_added="false"

    for raw_num in "${number_list[@]}"; do
        # Trim whitespace
        local num
        num="${raw_num#"${raw_num%%[![:space:]]*}"}"
        num="${num%"${num##*[![:space:]]}"}"

        # Validate: must be a positive integer
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
            failed_arr+=("{\"number\":\"$(json_str "$num")\",\"error\":\"invalid issue number — must be a positive integer\"}")
            continue
        fi

        local cmd=(gh issue close "$num" -R "$repo")
        [[ -n "$comment" ]] && cmd+=(--comment "$comment")

        local stderr_file
        stderr_file=$(mktemp)
        if ! "${cmd[@]}" >/dev/null 2>"$stderr_file"; then
            local stderr_content
            stderr_content=$(cat "$stderr_file")
            rm -f "$stderr_file"
            failed_arr+=("{\"number\":$num,\"error\":\"$(json_str "$stderr_content")\"}")
        else
            rm -f "$stderr_file"
            closed_arr+=("$num")
        fi
    done

    # Build JSON arrays
    local closed_json="["
    local first=1
    for n in "${closed_arr[@]:-}"; do
        [[ -z "$n" ]] && continue
        [[ $first -eq 0 ]] && closed_json+=","
        closed_json+="$n"
        first=0
    done
    closed_json+="]"

    local failed_json="["
    first=1
    for f in "${failed_arr[@]:-}"; do
        [[ -z "$f" ]] && continue
        [[ $first -eq 0 ]] && failed_json+=","
        failed_json+="$f"
        first=0
    done
    failed_json+="]"

    printf '{"closed":%s,"failed":%s,"comment_added":%s}\n' \
        "$closed_json" "$failed_json" "$comment_added"
}

# ---------------------------------------------------------------------------
# tool: search_issues
# ---------------------------------------------------------------------------

tool_search_issues() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "query"
    local query="${OPTS[query]}"
    local limit
    limit=$(opt "limit" "20")
    local state
    state=$(opt "state" "")

    check_gh

    local cmd=(gh issue list -R "$repo" --search "$query" -L "$limit"
        --json "number,title,state,labels,url")
    [[ -n "$state" ]] && cmd+=(--state "$state")

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$("${cmd[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "gh issue search failed" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    python3 - "$raw" <<'PYEOF'
import sys, json

try:
    issues = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({"error": f"Failed to parse gh output: {e}", "exit_code": 1, "stderr": ""}))
    sys.exit(0)

out = []
for iss in issues:
    out.append({
        "number": iss.get("number"),
        "title": iss.get("title", ""),
        "state": iss.get("state", ""),
        "labels": [l["name"] for l in (iss.get("labels") or [])],
        "url": iss.get("url", ""),
    })

print(json.dumps({"issues": out, "total_count": len(out)}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: sub_issue
# ---------------------------------------------------------------------------

tool_sub_issue() {
    parse_named_args "$@"

    require_opt "repo"
    local repo="${OPTS[repo]}"
    require_opt "parent"
    local parent="${OPTS[parent]}"
    validate_number "$parent"
    require_opt "child"
    local child="${OPTS[child]}"
    validate_number "$child"

    check_gh

    # Step 1: get child issue node_id
    local child_raw stderr_file
    stderr_file=$(mktemp)
    if ! child_raw=$(gh api "repos/$repo/issues/$child" --jq '.node_id' 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "Failed to fetch child issue #$child node_id" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    local node_id
    node_id=$(printf '%s' "$child_raw" | tr -d '[:space:]')
    if [[ -z "$node_id" ]]; then
        json_error "Child issue #$child has empty node_id — issue may not exist" 1
    fi

    # Step 2: link child as sub-issue of parent
    local link_raw
    stderr_file=$(mktemp)
    if ! link_raw=$(gh api --method POST "repos/$repo/issues/$parent/sub_issues" \
        --field "sub_issue_id=$node_id" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "Failed to link #$child as sub-issue of #$parent" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    printf '{"parent":%s,"child":%s,"node_id":"%s","linked":true}\n' \
        "$parent" "$child" "$(json_str "$node_id")"
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

check_git() {
    if ! command -v git &>/dev/null; then
        json_error "git not found in PATH" 127
    fi
}

# cd into repo_path if provided, else stay in cwd.
# Sets global REPO_PATH for use in subsequent git calls.
setup_repo_path() {
    local repo_path="$1"
    if [[ -n "$repo_path" ]]; then
        if [[ ! -d "$repo_path" ]]; then
            json_error "repo-path does not exist: $repo_path" 1
        fi
        cd "$repo_path"
    fi
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        json_error "Not a git repository: $(pwd)" 1
    fi
}

# ---------------------------------------------------------------------------
# tool: git_status
# ---------------------------------------------------------------------------

tool_git_status() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    check_git
    setup_repo_path "$repo_path"

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'DETACHED')

    local porcelain
    local stderr_file
    stderr_file=$(mktemp)
    if ! porcelain=$(git status --porcelain 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "git status failed" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    # ahead/behind relative to upstream
    local ahead=0 behind=0
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
    if [[ -n "$upstream" ]]; then
        local counts
        counts=$(git rev-list --left-right --count HEAD..."$upstream" 2>/dev/null || printf '0\t0')
        ahead=$(printf '%s' "$counts" | awk '{print $1}')
        behind=$(printf '%s' "$counts" | awk '{print $2}')
    fi

    python3 - "$branch" "$porcelain" "$ahead" "$behind" <<'PYEOF'
import sys, json

branch = sys.argv[1]
porcelain = sys.argv[2]
ahead = int(sys.argv[3])
behind = int(sys.argv[4])

staged = []
modified = []
untracked = []

for line in porcelain.splitlines():
    if len(line) < 2:
        continue
    x, y, path = line[0], line[1], line[3:]
    if x == '?' and y == '?':
        untracked.append(path)
    else:
        if x not in (' ', '?'):
            staged.append(path)
        if y not in (' ', '?'):
            modified.append(path)

clean = (len(staged) == 0 and len(modified) == 0 and len(untracked) == 0)
print(json.dumps({
    "branch": branch,
    "clean": clean,
    "staged": staged,
    "modified": modified,
    "untracked": untracked,
    "ahead": ahead,
    "behind": behind,
}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: git_diff
# ---------------------------------------------------------------------------

tool_git_diff() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    local staged
    staged=$(opt "staged" "false")
    local stat_only
    stat_only=$(opt "stat-only" "false")
    check_git
    setup_repo_path "$repo_path"

    local stat_args=(git diff --numstat)
    local diff_args=(git diff)
    if [[ "$staged" == "true" ]]; then
        stat_args+=(--cached)
        diff_args+=(--cached)
    fi

    local stderr_file numstat diff_output
    stderr_file=$(mktemp)
    if ! numstat=$("${stat_args[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "git diff --numstat failed" 1 "$stderr_content"
    fi

    diff_output=""
    if [[ "$stat_only" != "true" ]]; then
        if ! diff_output=$("${diff_args[@]}" 2>"$stderr_file"); then
            local stderr_content
            stderr_content=$(cat "$stderr_file")
            rm -f "$stderr_file"
            json_error "git diff failed" 1 "$stderr_content"
        fi
    fi
    rm -f "$stderr_file"

    python3 - "$numstat" "$diff_output" "$stat_only" <<'PYEOF'
import sys, json

numstat = sys.argv[1]
diff_output = sys.argv[2]
stat_only = sys.argv[3] == "true"

files = []
total_ins = 0
total_del = 0

for line in numstat.splitlines():
    parts = line.split("\t", 2)
    if len(parts) != 3:
        continue
    ins_s, del_s, path = parts
    ins = int(ins_s) if ins_s.isdigit() else 0
    dels = int(del_s) if del_s.isdigit() else 0
    total_ins += ins
    total_del += dels
    files.append({"path": path, "insertions": ins, "deletions": dels})

result = {
    "files_changed": len(files),
    "insertions": total_ins,
    "deletions": total_del,
    "files": files,
}
if not stat_only:
    result["diff"] = diff_output

print(json.dumps(result))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: git_log
# ---------------------------------------------------------------------------

tool_git_log() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    local limit
    limit=$(opt "limit" "10")
    local since
    since=$(opt "since" "")
    check_git
    setup_repo_path "$repo_path"

    local cmd=(git log "--pretty=format:%H%x1F%h%x1F%an%x1F%aI%x1F%s" "-$limit")
    [[ -n "$since" ]] && cmd+=(--since="$since")

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$("${cmd[@]}" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "git log failed" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    python3 - "$raw" <<'PYEOF'
import sys, json

raw = sys.argv[1]
commits = []
for line in raw.splitlines():
    parts = line.split("\x1f", 4)
    if len(parts) != 5:
        continue
    hash_, short_hash, author, date, message = parts
    commits.append({
        "hash": hash_,
        "short_hash": short_hash,
        "author": author,
        "date": date,
        "message": message,
    })
print(json.dumps({"commits": commits}))
PYEOF
}

# ---------------------------------------------------------------------------
# tool: stage_files
# ---------------------------------------------------------------------------

tool_stage_files() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    require_opt "files"
    local files_raw="${OPTS[files]}"
    check_git
    setup_repo_path "$repo_path"

    IFS=',' read -ra file_list <<< "$files_raw"

    local staged_arr=()
    local errors_arr=()

    for raw_file in "${file_list[@]}"; do
        # Trim whitespace
        local f
        f="${raw_file#"${raw_file%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [[ -z "$f" ]] && continue

        local stderr_file
        stderr_file=$(mktemp)
        if ! git add -- "$f" 2>"$stderr_file"; then
            local stderr_content
            stderr_content=$(cat "$stderr_file")
            rm -f "$stderr_file"
            errors_arr+=("{\"file\":\"$(json_str "$f")\",\"error\":\"$(json_str "$stderr_content")\"}")
        else
            rm -f "$stderr_file"
            staged_arr+=("\"$(json_str "$f")\"")
        fi
    done

    local staged_json="[$(IFS=','; printf '%s' "${staged_arr[*]:-}")]"
    local errors_json="[$(IFS=','; printf '%s' "${errors_arr[*]:-}")]"
    printf '{"staged":%s,"errors":%s}\n' "$staged_json" "$errors_json"
}

# ---------------------------------------------------------------------------
# tool: create_commit
# ---------------------------------------------------------------------------

tool_create_commit() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    require_opt "message"
    local message="${OPTS[message]}"
    local co_author
    co_author=$(opt "co-author" "Claude Opus 4.6 (1M context) <noreply@anthropic.com>")
    check_git
    setup_repo_path "$repo_path"

    # Append Co-Authored-By trailer if co-author is non-empty
    local full_message="$message"
    if [[ -n "$co_author" ]]; then
        full_message="$message

Co-Authored-By: $co_author"
    fi

    local raw stderr_file
    stderr_file=$(mktemp)
    if ! raw=$(git commit -m "$full_message" 2>"$stderr_file"); then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        local stdout_content="$raw"
        rm -f "$stderr_file"
        json_error "git commit failed: $(printf '%s' "$stdout_content $stderr_content" | head -c 500)" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    local hash short_hash files_committed
    hash=$(git rev-parse HEAD 2>/dev/null || printf '')
    short_hash=$(git rev-parse --short HEAD 2>/dev/null || printf '')
    # Count files in the commit
    files_committed=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')

    printf '{"hash":"%s","short_hash":"%s","message":"%s","files_committed":%s}\n' \
        "$(json_str "$hash")" "$(json_str "$short_hash")" "$(json_str "$message")" "$files_committed"
}

# ---------------------------------------------------------------------------
# tool: git_push
# ---------------------------------------------------------------------------

tool_git_push() {
    parse_named_args "$@"
    local repo_path
    repo_path=$(opt "repo-path" "")
    local remote
    remote=$(opt "remote" "origin")
    local branch
    branch=$(opt "branch" "")

    # Safety: refuse force push regardless of any args
    if [[ -n "${OPTS[force]:-}" ]]; then
        json_error "Force push is not allowed" 1
    fi

    check_git
    setup_repo_path "$repo_path"

    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')
    fi

    # Count commits that will be pushed
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
    local commits_pushed=0
    if [[ -n "$upstream" ]]; then
        commits_pushed=$(git rev-list --count "$upstream"..HEAD 2>/dev/null || printf '0')
    fi

    local stderr_file
    stderr_file=$(mktemp)
    if ! git push "$remote" "$branch" 2>"$stderr_file"; then
        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"
        json_error "git push failed" 1 "$stderr_content"
    fi
    rm -f "$stderr_file"

    printf '{"pushed":true,"remote":"%s","branch":"%s","commits_pushed":%s}\n' \
        "$(json_str "$remote")" "$(json_str "$branch")" "$commits_pushed"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

TOOL="${1:-}"
shift || true

# Normalise: server.ts uses hyphens (list-issues), script uses underscores.
TOOL="${TOOL//-/_}"

case "$TOOL" in
    list_issues)    tool_list_issues    "$@" ;;
    create_issue)   tool_create_issue   "$@" ;;
    close_issue)    tool_close_issue    "$@" ;;
    batch_close)    tool_batch_close    "$@" ;;
    reopen_issue)   tool_reopen_issue   "$@" ;;
    view_issue)     tool_view_issue     "$@" ;;
    add_comment)    tool_add_comment    "$@" ;;
    search_issues)  tool_search_issues  "$@" ;;
    git_status)     tool_git_status     "$@" ;;
    git_diff)       tool_git_diff       "$@" ;;
    git_log)        tool_git_log        "$@" ;;
    stage_files)    tool_stage_files    "$@" ;;
    create_commit)  tool_create_commit  "$@" ;;
    git_push)       tool_git_push       "$@" ;;
    sub_issue)      tool_sub_issue      "$@" ;;
    "")
        printf '{"error":"No tool specified","available":["list_issues","create_issue","close_issue","batch_close","reopen_issue","view_issue","add_comment","search_issues","git_status","git_diff","git_log","stage_files","create_commit","git_push","sub_issue"]}\n'
        exit 1
        ;;
    *)
        printf '{"error":"Unknown tool: %s","available":["list_issues","create_issue","close_issue","batch_close","reopen_issue","view_issue","add_comment","search_issues","git_status","git_diff","git_log","stage_files","create_commit","git_push","sub_issue"]}\n' "$(json_str "$TOOL")"
        exit 1
        ;;
esac
