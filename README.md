# ARIA — Automated Review Intelligence Agents

ARIA is a multi-persona AI code review system that integrates with GitLab CI/CD pipelines. When triggered on a merge request, it runs up to five specialized AI reviewers against the changed files and posts inline diff comments directly to the MR.

## How It Works

```
MR trigger
    └─► gitlab-mr-changed-files.sh   (fetch changed file paths via GitLab API)
            └─► generate-review-comments.sh  (run each AI persona via opencode CLI)
                    └─► gitlab-mr-post-comments.sh  (post inline MR discussions)
```

Each persona has a narrowly scoped focus:

| Persona | Focus |
|---|---|
| `functional` | Correctness, logic errors, edge cases |
| `architecture` | Design patterns, coupling, responsibility boundaries |
| `security` | Vulnerabilities, injection risks, secret handling |
| `performance` | Algorithmic complexity, resource usage, bottlenecks |
| `readability` | Naming, clarity, maintainability |

## Prerequisites

- GitLab instance with REST API v4
- Docker (for CI) or local: `bash`, `curl`, `jq`, `python3`, `git`
- [opencode](https://github.com/sst/opencode) CLI (installed in the Docker image)

## Project Structure

```
aria/
├── .github/workflows/
│   └── build-image.yml             # Builds the image and pushes it to ghcr.io
├── ci/
│   ├── aria-review.yml             # CI job template for Docker-executor runners
│   └── aria-review-shell.yml       # CI job template for shell runners (uses docker run)
├── tests/
│   ├── test_resolve_profiles.sh
│   ├── test_generate_config.sh
│   ├── test_post_comments.sh
│   ├── test_credentials.sh
│   ├── test_review_comments.sh
│   └── test_ci_template.sh
├── Dockerfile
├── opencode.json.template          # opencode agent config template
├── aria-review-job.sh              # Runs the whole review for one MR (used by both templates)
├── generate-opencode-config.sh     # Renders opencode.json at runtime
├── generate-review-comments.sh     # Orchestrates AI persona reviews
├── gitlab-mr-changed-files.sh      # Fetches changed files from GitLab API
├── gitlab-mr-post-comments.sh      # Posts findings as inline MR discussions
└── resolve-profiles.sh             # Filters personas by ARIA_PROFILES
```

## Integration: Adding AI Review to a Project

### 1. Set group-level CI/CD variables

In GitLab: **Group → Settings → CI/CD → Variables**

| Variable | Required | Description |
|---|---|---|
| `GITLAB_URL` | yes | e.g. `https://gitlab.example.com` |
| `GITLAB_TOKEN` | yes | Token with `api` scope |
| `ARIA_REVIEW_IMAGE` | yes | `ghcr.io/ssattv/aria:latest` |
| `ARIA_MODEL` | no | e.g. `openai/gpt-4o` |
| `ARIA_MODEL_API_KEY` | no | Provider API key |
| `ARIA_MODEL_BASE_URL` | no | Endpoint override for self-hosted LLMs |
| `ARIA_PROFILES` | no | Comma-separated subset of personas (default: all five) |

### 2. Include the job template

```yaml
# .gitlab-ci.yml in the target project
include:
  - project: 'your-group/aria'
    ref: main
    file: 'ci/aria-review.yml'

stages:
  - review
```

The job is tagged `docker`, so it needs a runner that:

- uses the **Docker executor** (a shell executor ignores `image:`, so opencode and the ARIA scripts are missing and the job fails),
- has the tag `docker`, and
- is **not protected** (MR pipelines run on unprotected refs).

To use a different tag, override it in your project:

```yaml
ai_code_review:
  tags: [my-docker-runner]
```

The job sets `before_script: []`, so your project's global `before_script` does not run in it.

#### Only shell runners? Use `ci/aria-review-shell.yml`

If your project only has **shell-executor** runners, include `ci/aria-review-shell.yml` instead of `ci/aria-review.yml` (not both):

```yaml
include:
  - project: 'your-group/aria'
    ref: main
    file: 'ci/aria-review-shell.yml'
```

This job runs on a shell runner tagged `local` and starts the ARIA image itself with `docker run`:

- The runner checks out the MR on the host, and the job fetches the target branch there. The checkout is mounted into the container at the same path.
- Variables are passed in by name (`-e GITLAB_TOKEN`), so secret values never appear on the command line or in files.
- The container runs as the runner user, so files it creates can be cleaned by the next job.
- The container uses the host network (`--network host`), so it reaches GitLab and the model API the same way the runner does.

Runner needs: the `local` tag (or override `tags:` as above), permission to run `docker`, and not protected.

Optional variable: `ARIA_DOCKER_PULL` sets the `docker run --pull` policy: `always` (default), `missing` or `never`. Use `missing` if pulling from the registry on every run is unreliable.

### 3. Trigger a review

Open an MR → **Pipelines** tab → click **Run** on the `ai_code_review` job. Inline comments appear on the diff when the job completes.

## Selective Persona Execution

Set `ARIA_PROFILES` to run only specific personas:

```
ARIA_PROFILES=security,performance   # only security and performance
ARIA_PROFILES=functional             # only functional
# unset or empty                     # all five personas (default)
```

## Local Development

### Run the test suite

```bash
bash tests/test_resolve_profiles.sh
bash tests/test_generate_config.sh
bash tests/test_post_comments.sh
bash tests/test_credentials.sh
bash tests/test_review_comments.sh
bash tests/test_ci_template.sh
```

### Run scripts manually

```bash
# Generate opencode config
ARIA_REVIEW_PATH=/path/to/repo ./generate-opencode-config.sh > opencode.json

# Fetch changed files from an MR
export GITLAB_URL="https://gitlab.example.com"
export GITLAB_TOKEN="your-token"
./gitlab-mr-changed-files.sh <project-id> <mr-iid> > /tmp/changed_files.txt

# Run review (requires opencode installed and opencode.json present)
export FEATURE_BRANCH="feature/your-branch"
export TARGET_BRANCH="main"
export CHANGED_FILES="/tmp/changed_files.txt"
./generate-review-comments.sh /tmp/comments.json

# Post comments
./gitlab-mr-post-comments.sh <project-id> <mr-iid> /tmp/comments.json
```

### Build the Docker image

```bash
docker build -t aria:local .

# Verify tooling
docker run --rm aria:local opencode --version
docker run --rm aria:local jq --version
```

## Docker Image

The image is built by GitHub Actions (`.github/workflows/build-image.yml`) on every push to `main` of the GitHub mirror, and pushed to GitHub Container Registry as `ghcr.io/ssattv/aria:latest`, plus `ghcr.io/ssattv/aria:sha-<short-sha>` for pinning a build. The GitHub mirror is https://github.com/ssattv/aria. It is built on GitHub because apt downloads are unreliable on our GitLab runner's network.

If the package is private, add a `DOCKER_AUTH_CONFIG` CI/CD variable in GitLab with a GitHub token that has `read:packages`, so runners can pull it.

Base: `ubuntu:24.04`  
Includes: `git`, `curl`, `jq`, `python3`, `opencode` binary, all ARIA scripts at `/opt/aria/`

## Error Handling

ARIA is designed to always leave feedback on the MR:

- Invalid or empty `comments.json` → posts a "no output" or "no issues found" note
- Failed inline comment positions → falls back to a summary note
- One persona crashes → remaining personas continue

## Artifacts

The job stores `.aria-review/comments.json` as a GitLab CI artifact (7-day retention), downloadable from the job detail page.
