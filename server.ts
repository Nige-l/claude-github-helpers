#!/usr/bin/env bun
/**
 * GitHub Helpers MCP server for Claude Code.
 *
 * Exposes GitHub issue management tools (list, create, close, reopen, view,
 * add_comment, search) by dispatching to bin/github-helpers.sh. Designed to
 * run under Bun with the MCP SDK's stdio transport.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { fileURLToPath } from 'url'
import { dirname, join } from 'path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(__dirname, 'bin', 'github-helpers.sh')

// Last-resort safety net — log and keep serving on unhandled errors.
process.on('unhandledRejection', err => {
  process.stderr.write(`github-helpers: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`github-helpers: uncaught exception: ${err}\n`)
})

// ---------------------------------------------------------------------------
// Helper: run the bash script and capture output
// ---------------------------------------------------------------------------

const SCRIPT_TIMEOUT_MS = 30_000

async function runScript(args: string[]): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = Bun.spawn(['bash', SCRIPT, ...args], {
    stdout: 'pipe',
    stderr: 'pipe',
    env: { ...process.env },
  })

  let timeoutId: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      proc.kill()
      reject(new Error(`Script timed out after ${SCRIPT_TIMEOUT_MS / 1000}s`))
    }, SCRIPT_TIMEOUT_MS)
  })

  let result: [string, string, number]
  try {
    result = await Promise.race([
      Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]),
      timeout,
    ])
  } catch (err) {
    clearTimeout(timeoutId!)
    throw err
  }
  clearTimeout(timeoutId!)
  const [stdout, stderr, exitCode] = result

  return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode }
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'github-helpers', version: '0.1.0' },
  { capabilities: { tools: {} } },
)

// ---------------------------------------------------------------------------
// ListTools
// ---------------------------------------------------------------------------

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'list_issues',
      description: 'List GitHub issues for a repository. Returns structured JSON with issue numbers, titles, labels, state, and assignees.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          state: { type: 'string', enum: ['open', 'closed', 'all'], description: 'Issue state filter. Default: open' },
          labels: { type: 'string', description: 'Comma-separated label names to filter by' },
          limit: { type: 'number', description: 'Maximum number of issues to return. Default: 30' },
          assignee: { type: 'string', description: 'Filter by assignee username' },
          milestone: { type: 'string', description: 'Filter by milestone title or number' },
        },
        required: ['repo'],
      },
    },
    {
      name: 'create_issue',
      description: 'Create a new GitHub issue.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          title: { type: 'string', description: 'Issue title' },
          body: { type: 'string', description: 'Issue body (markdown supported)' },
          labels: { type: 'string', description: 'Comma-separated label names to apply' },
          assignee: { type: 'string', description: 'Username to assign the issue to' },
        },
        required: ['repo', 'title'],
      },
    },
    {
      name: 'close_issue',
      description: 'Close a GitHub issue, optionally adding a closing comment.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          number: { type: 'number', description: 'Issue number to close' },
          comment: { type: 'string', description: 'Optional comment to post before closing' },
        },
        required: ['repo', 'number'],
      },
    },
    {
      name: 'reopen_issue',
      description: 'Reopen a closed GitHub issue, optionally adding a comment.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          number: { type: 'number', description: 'Issue number to reopen' },
          comment: { type: 'string', description: 'Optional comment to post when reopening' },
        },
        required: ['repo', 'number'],
      },
    },
    {
      name: 'view_issue',
      description: 'View the full details of a GitHub issue including body and comments.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          number: { type: 'number', description: 'Issue number to view' },
        },
        required: ['repo', 'number'],
      },
    },
    {
      name: 'add_comment',
      description: 'Add a comment to an existing GitHub issue.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          number: { type: 'number', description: 'Issue number to comment on' },
          body: { type: 'string', description: 'Comment body (markdown supported)' },
        },
        required: ['repo', 'number', 'body'],
      },
    },
    {
      name: 'search_issues',
      description: 'Search GitHub issues within a repository using a query string.',
      inputSchema: {
        type: 'object' as const,
        properties: {
          repo: { type: 'string', description: 'Repository in "owner/repo" format' },
          query: { type: 'string', description: 'Search query string' },
          limit: { type: 'number', description: 'Maximum number of results to return. Default: 20' },
          state: { type: 'string', enum: ['open', 'closed', 'all'], description: 'Filter results by state' },
        },
        required: ['repo', 'query'],
      },
    },
  ],
}))

// ---------------------------------------------------------------------------
// CallTool
// ---------------------------------------------------------------------------

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params

  try {
    switch (name) {
      case 'list_issues': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'list_issues: repo is required and must be a non-empty string' }], isError: true }
        }
        const cmdArgs = ['list_issues', '--repo', args.repo]
        if (args?.state) cmdArgs.push('--state', String(args.state))
        if (args?.labels) cmdArgs.push('--labels', String(args.labels))
        if (args?.limit !== undefined) cmdArgs.push('--limit', String(args.limit))
        if (args?.assignee) cmdArgs.push('--assignee', String(args.assignee))
        if (args?.milestone) cmdArgs.push('--milestone', String(args.milestone))
        return formatResult(await runScript(cmdArgs))
      }

      case 'create_issue': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'create_issue: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.title !== 'string' || args.title === '') {
          return { content: [{ type: 'text', text: 'create_issue: title is required and must be a non-empty string' }], isError: true }
        }
        const cmdArgs = ['create_issue', '--repo', args.repo, '--title', args.title]
        if (args?.body) cmdArgs.push('--body', String(args.body))
        if (args?.labels) cmdArgs.push('--labels', String(args.labels))
        if (args?.assignee) cmdArgs.push('--assignee', String(args.assignee))
        return formatResult(await runScript(cmdArgs))
      }

      case 'close_issue': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'close_issue: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.number !== 'number') {
          return { content: [{ type: 'text', text: 'close_issue: number is required and must be a number' }], isError: true }
        }
        const cmdArgs = ['close_issue', '--repo', args.repo, '--number', String(args.number)]
        if (args?.comment) cmdArgs.push('--comment', String(args.comment))
        return formatResult(await runScript(cmdArgs))
      }

      case 'reopen_issue': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'reopen_issue: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.number !== 'number') {
          return { content: [{ type: 'text', text: 'reopen_issue: number is required and must be a number' }], isError: true }
        }
        const cmdArgs = ['reopen_issue', '--repo', args.repo, '--number', String(args.number)]
        if (args?.comment) cmdArgs.push('--comment', String(args.comment))
        return formatResult(await runScript(cmdArgs))
      }

      case 'view_issue': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'view_issue: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.number !== 'number') {
          return { content: [{ type: 'text', text: 'view_issue: number is required and must be a number' }], isError: true }
        }
        const cmdArgs = ['view_issue', '--repo', args.repo, '--number', String(args.number)]
        return formatResult(await runScript(cmdArgs))
      }

      case 'add_comment': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'add_comment: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.number !== 'number') {
          return { content: [{ type: 'text', text: 'add_comment: number is required and must be a number' }], isError: true }
        }
        if (typeof args?.body !== 'string' || args.body === '') {
          return { content: [{ type: 'text', text: 'add_comment: body is required and must be a non-empty string' }], isError: true }
        }
        const cmdArgs = ['add_comment', '--repo', args.repo, '--number', String(args.number), '--body', args.body]
        return formatResult(await runScript(cmdArgs))
      }

      case 'search_issues': {
        if (typeof args?.repo !== 'string' || args.repo === '') {
          return { content: [{ type: 'text', text: 'search_issues: repo is required and must be a non-empty string' }], isError: true }
        }
        if (typeof args?.query !== 'string' || args.query === '') {
          return { content: [{ type: 'text', text: 'search_issues: query is required and must be a non-empty string' }], isError: true }
        }
        const cmdArgs = ['search_issues', '--repo', args.repo, '--query', args.query]
        if (args?.limit !== undefined) cmdArgs.push('--limit', String(args.limit))
        if (args?.state) cmdArgs.push('--state', String(args.state))
        return formatResult(await runScript(cmdArgs))
      }

      default:
        return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true }
    }
  } catch (err: any) {
    const msg = err?.message ?? String(err)
    return {
      content: [{ type: 'text', text: `Error running ${name}: ${msg}` }],
      isError: true,
    }
  }
})

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatResult(result: { stdout: string; stderr: string; exitCode: number }) {
  if (result.exitCode === 0) {
    return { content: [{ type: 'text' as const, text: result.stdout || 'OK' }] }
  }
  return { content: [{ type: 'text' as const, text: result.stderr || result.stdout || 'Command failed' }], isError: true }
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport()
await server.connect(transport)
