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
    [[ -n "$BODY_TEMP_FILE" ]] && rm -f "$BODY_TEMP_FILE" && BODY_TEMP_FILE=""
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
    reopen_issue)   tool_reopen_issue   "$@" ;;
    view_issue)     tool_view_issue     "$@" ;;
    add_comment)    tool_add_comment    "$@" ;;
    search_issues)  tool_search_issues  "$@" ;;
    "")
        printf '{"error":"No tool specified","available":["list_issues","create_issue","close_issue","reopen_issue","view_issue","add_comment","search_issues"]}\n'
        exit 1
        ;;
    *)
        printf '{"error":"Unknown tool: %s","available":["list_issues","create_issue","close_issue","reopen_issue","view_issue","add_comment","search_issues"]}\n' "$(json_str "$TOOL")"
        exit 1
        ;;
esac
