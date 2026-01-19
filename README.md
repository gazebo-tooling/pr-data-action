# PR Data Validation Action

A GitHub Action that validates pull requests contain a changelog file in the `.changelog` directory.

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

## What it checks

### Changelog File
The action checks if the PR includes any new or modified files in the specified changelog directory (`.changelog` by default).

**Example changelog file structure:**
```
.changelog/
├── fix-login-bug.md
├── add-user-profile.md
└── breaking-change-api.md
```

## Error Messages

The action provides helpful error messages when validation fails:

### Missing Changelog
```
📝 Please add a changelog file to document your changes:
   1. Create a new file in the .changelog/ directory
   2. Name it descriptively (e.g., fix-bug-123.md, add-new-feature.md)
   3. Document what changed, why, and any breaking changes
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
