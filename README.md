# berget-code-runner

Containerized headless runner for [Berget Code](https://berget.ai) using the [OpenCode](https://opencode.ai) harness. Clones a git repository, configures OpenCode to use the Berget AI OpenAI-compatible API, and runs a one-shot agent session against the repo.

Follows the same pattern as [claude-runner](https://github.com/birme/claude-runner) and [codex-runner](https://github.com/birme/codex-runner).

## Required environment variables

| Variable | Description |
|---|---|
| `BERGET_API_KEY` | Berget AI API key |
| `SOURCE_URL` | Git repository URL to clone (also accepted as `GITHUB_URL`) |
| `PROMPT` | Task for the agent to perform |

## Optional environment variables

| Variable | Default | Description |
|---|---|---|
| `MODEL` | `google/gemma-4-31B-it` | Berget model id or alias, with or without a leading `berget/`. Any model that Berget serves with tool calling works; the ones currently listed at `https://api.berget.ai/v1/models` are `moonshotai/Kimi-K3.1-Pro`, `zai-org/GLM-5.3-Flash`, `google/gemma-4-31B-it` and `mistralai/Mistral-Small-3.2-24B-Instruct-2506`. A retired model fails the run with Berget's own error. |
| `BERGET_BASE_URL` | `https://api.berget.ai/v1` | Berget AI API base URL |
| `GIT_BRANCH` | _(default branch)_ | Branch to check out. Can also be appended to `SOURCE_URL` as `url#branch`. |
| `GIT_TOKEN` | | Personal access token for cloning private repositories (also accepted as `GITHUB_TOKEN`) |
| `SUB_PATH` | | Subdirectory within the cloned repo to use as the working directory |
| `VERBOSE` | `1` | Rich logging. By default the runner streams OpenCode's JSON events and formats them into human-readable stdout (assistant text, tool calls, tool results, step summaries). Set to `0` or `false` for OpenCode's plain text output. |
| `RAW_JSON` | `0` | Set to `1` or `true` to emit the raw JSONL events instead of formatted output. |
| `ALLOWEDTOOLS`, `DISALLOWEDTOOLS` | | Accepted for compatibility with claude-runner but ignored (they use Claude Code tool names). |
| `CONFIG_API_KEY` | | API key for an encrypted parameter store. Used with `OSC_ACCESS_TOKEN` and `CONFIG_SVC` so secret parameters are decrypted before being injected as environment variables. |
| `GIT_TOKEN_REFRESH` | | Per-run nonce for refreshing a GitHub connection token. Set by deploy-manager for agent tasks with `githubConnection`. Together with `DEPLOY_MANAGER_URL`, `TASK_ID`, `RUN_ID` and `TENANT_ID` it starts a background loop that fetches a new token every 45 minutes (`TOKEN_REFRESH_INTERVAL` seconds to override) into a 0600 tmpfs file. The git credential helper reads that file when present and `GIT_TOKEN` otherwise. A refresh failure keeps the old token. |
| `DEPLOY_MANAGER_URL`, `TASK_ID`, `RUN_ID`, `TENANT_ID` | | Used with `GIT_TOKEN_REFRESH` as above. |

`gh` is wrapped by a shim that exports `GH_TOKEN` from the refreshed token file, except when `GH_TOKEN` was loaded from the parameter store (`GH_TOKEN_SOURCE=paramstore`): a parameter-store `GH_TOKEN` always wins.
| `MAX_TURNS` | _(unlimited)_ | Accepted but ignored; OpenCode `run` has no turn-limit flag |
| `OSC_ACCESS_TOKEN` | | OSC service access token. If set, the OSC MCP server is wired into OpenCode. |
| `OSC_MCP_URL` | `https://mcp.osaas.io/mcp` | OSC MCP endpoint |
| `OSC_ENV` | `prod` | OSC environment (`dev`, `stage`, `prod`). Auto-detected from `OSC_MCP_URL` if not set. |
| `CONFIG_SVC` | | OSC app-config-svc instance name. If set (with `OSC_ACCESS_TOKEN`), environment variables are loaded from this config service before the agent starts. |
| `EMBED_API_KEY` | `0` | Set to `1` to write the literal `BERGET_API_KEY` into the OpenCode config file instead of using `{env:BERGET_API_KEY}` templating. Only needed if a future OpenCode version does not support env templating at provider init. |

## Usage

### Basic usage

```bash
docker run --rm \
  -e BERGET_API_KEY=your-berget-api-key \
  -e SOURCE_URL=https://github.com/your-org/your-repo \
  -e PROMPT="Add a health check endpoint to the Express app" \
  ghcr.io/birme/berget-code-runner:latest
```

### Private repository with model selection

```bash
docker run --rm \
  -e BERGET_API_KEY=your-berget-api-key \
  -e SOURCE_URL=https://github.com/your-org/private-repo \
  -e GIT_TOKEN=ghp_yourtoken \
  -e MODEL=mistral-medium-3.5 \
  -e PROMPT="Refactor the authentication module to use JWT" \
  ghcr.io/birme/berget-code-runner:latest
```

### With OSC MCP server

```bash
docker run --rm \
  -e BERGET_API_KEY=your-berget-api-key \
  -e SOURCE_URL=https://github.com/your-org/your-repo \
  -e PROMPT="Deploy the updated service to the dev environment" \
  -e OSC_ACCESS_TOKEN=your-osc-token \
  -e OSC_MCP_URL=https://ai.svc.dev.osaas.io/mcp \
  ghcr.io/birme/berget-code-runner:latest
```

## What goes in the repository

The runner respects standard agent configuration files in the cloned repo:

- **`AGENTS.md`** — OpenCode reads this file for project-specific agent instructions and constraints.
- **`.opencode/`** — OpenCode configuration directory. Place `config.json` here to override provider settings, tool access, or other session options at the project level.

## Behavior

1. Start as root, fix `/usercontent` ownership, then drop to the `node` user.
2. Validate `BERGET_API_KEY`, `SOURCE_URL`, and `PROMPT`.
3. Clone the repository (shallow, single branch) into `/usercontent`. Private repos authenticate through a git credential helper, so the token never appears in the remote URL or git config.
4. If `OSC_ACCESS_TOKEN` and `CONFIG_SVC` are both set, refresh the access token and load environment variables from the OSC config service.
5. Start the background GitHub token refresher when `GIT_TOKEN_REFRESH` is set, and authenticate the GitHub CLI if `GITHUB_TOKEN` is available.
6. Write `~/.config/opencode/opencode.json` with the Berget AI provider definition (the four models above, plus the one named in `MODEL`; the selected model is always passed to OpenCode as `berget/<id>`). `autoupdate: false` is set to prevent update prompts in headless runs.
7. If `OSC_ACCESS_TOKEN` is set, patch the OpenCode config to add the OSC MCP remote server (the token is referenced as `{env:OSC_ACCESS_TOKEN}`, not written to disk) and exit with an error if the registration did not stick.
8. Run `opencode run --dangerously-skip-permissions [--model ...] --format json "$PROMPT"`, pipe the events through the formatter (unless `RAW_JSON=1` or `VERBOSE=0`) and exit with OpenCode's exit code.

## Tests

`npm test` runs the token refresh, gh shim, credential helper and stream formatter tests.

## License

MIT License. Copyright 2026 Jonas Birme.
