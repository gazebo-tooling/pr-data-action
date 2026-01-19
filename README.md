# PR Data Validation Action

A GitHub Action that validates pull requests contain a changelog file in the `.changelog` directory with content following the [Conventional Commits](https://www.conventionalcommits.org/) specification.

## Usage

Add this action to your workflow file (e.g., `.github/workflows/pr-validation.yml`):

```yaml
name: PR Validation
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Validate PR Data
        uses:gazebo-tooling/pr-data-action
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          changelog-dir: '.changelog'  # Optional, defaults to '.changelog'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `token` | GitHub token for API access | Yes | `${{ github.token }}` |
| `changelog-dir` | Directory where changelog files should be located | No | `.changelog` |

## Outputs

| Output | Description |
|--------|-------------|
| `changelog-found` | Whether a changelog file was found |
| `changelog-valid` | Whether the changelog content follows conventional commits format |

## What it checks

### 1. Changelog File Presence
The action checks if the PR includes any new or modified files in the specified changelog directory (`.changelog` by default).

**Example changelog file structure:**
```
.changelog/
├── fix-login-bug.md
├── add-user-profile.md
└── breaking-change-api.md
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
```
```
feat!: redesign authentication flow
```

**Format specification:**
- `type`: The type of change (e.g., `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`)
- `scope` (optional): The scope of the change in parentheses (e.g., `(api)`, `(ui)`)
- `!` (optional): Indicates a breaking change
- `description`: A short description of the change

## Error Messages

The action provides helpful error messages when validation fails:

### Missing Changelog
```
📝 Please add a changelog file to document your changes:
   1. Create a new file in the .changelog/ directory
   2. Name it descriptively (e.g., fix-bug-123.md, add-new-feature.md)
   3. The content must follow conventional commits format
```

### Invalid Changelog Format
When a changelog file is found but its content doesn't follow conventional commits format:
```
- ❌ Invalid changelog content format
  - The changelog content must follow the Conventional Commits specification
  - Error: <specific error from validator>
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

./validate-pr.sh
```
