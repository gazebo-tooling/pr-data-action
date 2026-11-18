# PR Data Validation Action

A GitHub Action that validates pull requests contain a changelog file in the `.changelog` directory with content following the [Conventional Commits](https://www.conventionalcommits.org/) specification.

The entries are turned into `Changelog.md` at release time by
[`create_changelog_entry.py`](https://github.com/gazebo-tooling/release-tools/tree/master/source-repo-scripts)
(gazebo-tooling/release-tools). The action applies the same rules, so an entry
that passes here can be released.

## Usage

Add this action to your workflow file (e.g., `.github/workflows/pr-validation.yml`):

```yaml
name: PR Validation
on:
  pull_request:
    branches: [main]
    # labeled/unlabeled re-run the check when the skip label changes
    types: [opened, synchronize, reopened, labeled, unlabeled]

permissions:
  contents: read
  pull-requests: read

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  changelog:
    runs-on: ubuntu-latest
    steps:
      - name: Validate changelog entries
        uses: gazebo-tooling/pr-data-action@<tag or commit SHA>
        with:
          changelog-dir: '.changelog'  # Optional, defaults to '.changelog'
          skip-label: 'no-changelog'   # Optional, defaults to 'no-changelog'
```

The action only reads from the GitHub API: it does not post reviews or
comments, so the read-only token of pull requests from forks is enough.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `token` | GitHub token used to read the pull request files (read access is enough) | Yes | `${{ github.token }}` |
| `changelog-dir` | Directory where changelog files should be located | No | `.changelog` |
| `skip-label` | Pull requests with this label pass without a changelog entry (e.g. forward ports, releases). Empty disables it. | No | `no-changelog` |

## Outputs

| Output | Description |
|--------|-------------|
| `changelog-found` | Whether the pull request adds or modifies at least one changelog entry |
| `changelog-valid` | Whether every changelog entry of the pull request is valid |

## What it checks

### 1. Changelog File Presence
The action checks if the PR includes any new or modified files in the specified changelog directory (`.changelog` by default).

Every file added, modified or renamed in the directory (subdirectories
included) is an entry, and every entry is validated. These files are not
entries:

- hidden files and files inside hidden directories, such as the
  `.changelog/.gitkeep` that keeps the directory when a release removes the
  last entry;
- removed files: the release commit removes the entries it processed. A
  release pull request has no new entry, so it needs the skip label.

**Example changelog file structure:**
```
.changelog/
├── .gitkeep
├── fix-login-bug.md
└── add-user-profile.md
```

### 2. Conventional Commits Format
The content of the changelog file must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification. This is validated using [cocogitto](https://github.com/cocogitto/cocogitto).

**Valid changelog content examples:**
```
feat: add user authentication
```
```
fix: resolve login timeout issue
```
```
feat(api): add new endpoint for user profiles
```
```
fix(ui): correct button alignment on mobile

Lines after the first one are the body of the entry.
```

**Format specification:**
- `type`: The type of change (e.g., `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`).
  A `feat` entry bumps the minor version at release time; other types bump the patch version.
- `scope` (optional): The scope of the change in parentheses (e.g., `(api)`, `(ui)`)
- `description`: A short description of the change
- Lines starting with `# ` are comments and are ignored.

**Breaking changes are rejected:** `feat!:` and `BREAKING CHANGE:` footers are
not supported by automatic releases, which never bump the major version. A
maintainer releases those changes manually.

## Results

A failing check reports the problems in three places:

- error annotations, shown in the checks list and, for invalid entries, on
  the file in the "Files changed" tab;
- the job summary, with the error of every invalid entry and how to write one;
- the job log.

### Missing Changelog
```
❌ Missing changelog entry

This pull request does not add or modify any file in `.changelog/`.
```

### Invalid Changelog Format
For each invalid entry, the reason, e.g.:
```
❌ Invalid changelog entries

.changelog/new-api.md
    Breaking changes ('!' after the type or a 'BREAKING CHANGE:' footer)
    are not supported by automatic releases. Ask a maintainer.
```

## Development

This action is implemented as a composite action using shell scripts, making it simple and dependency-free.

### Files
- `action.yml` - Action metadata and configuration
- `validate-pr.sh` - Main validation script

### Testing
You can test the action locally by setting the required environment variables:

```bash
export GITHUB_TOKEN="your-token"
export GITHUB_REPOSITORY="owner/repo"
export GITHUB_EVENT_NAME="pull_request"
export GITHUB_EVENT_PATH="/path/to/event.json"
export CHANGELOG_DIR=".changelog"
export SKIP_LABEL="no-changelog"
# Optional: a fake API server; the default is https://api.github.com
export GITHUB_API_URL="http://127.0.0.1:8080"

./validate-pr.sh
```
