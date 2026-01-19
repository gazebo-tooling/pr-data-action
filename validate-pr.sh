#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CHANGELOG_DIR="${CHANGELOG_DIR:-.changelog}"

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in a pull request context
check_pr_context() {
    if [[ "${GITHUB_EVENT_NAME}" != "pull_request" ]]; then
        log_error "This action should only run on pull request events"
        exit 1
    fi
}

# Get PR number from GitHub context
get_pr_number() {
    if [[ -f "${GITHUB_EVENT_PATH}" ]]; then
        # Extract PR number directly from the event JSON using jq
        PR_NUMBER=$(jq -r '.pull_request.number' "${GITHUB_EVENT_PATH}")

        if [[ -z "${PR_NUMBER}" || "${PR_NUMBER}" == "null" ]]; then
            log_error "Could not extract PR number from event data"
            exit 1
        fi

        echo "${PR_NUMBER}"
    else
        log_error "GITHUB_EVENT_PATH is not set or file does not exist"
        exit 1
    fi
}

# Get list of files changed in the PR
get_changed_files() {
    local pr_number=$1

    # Use GitHub API to get PR files
    curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/files" \
        | jq -r '.[].filename'
}

# Check if changelog file exists in changed files
# Sets CHANGELOG_FILE global variable with the found file path
check_changelog_file() {
    local changed_files="$1"
    CHANGELOG_FILE=""

    log_info "Checking for changelog files in ${CHANGELOG_DIR}/ directory..."

    while IFS= read -r file; do
        if [[ "${file}" == "${CHANGELOG_DIR}/"* ]]; then
            log_info "Found changelog file: ${file}"
            CHANGELOG_FILE="${file}"
            break
        fi
    done <<< "${changed_files}"

    if [[ -z "${CHANGELOG_FILE}" ]]; then
        log_error "No changelog file found in ${CHANGELOG_DIR}/ directory"
        echo ""
        echo "📝 Please add a changelog file to document your changes:"
        echo "   1. Create a new file in the ${CHANGELOG_DIR}/ directory"
        echo "   2. Name it descriptively (e.g., fix-bug-123.md, add-new-feature.md)"
        echo "   3. The content must follow conventional commits format"
        echo ""
        return 1
    fi

    return 0
}

# Get the head SHA of the PR for fetching file content
get_pr_head_sha() {
    if [[ -f "${GITHUB_EVENT_PATH}" ]]; then
        jq -r '.pull_request.head.sha' "${GITHUB_EVENT_PATH}"
    else
        echo ""
    fi
}

# Validate changelog content follows conventional commits format
# Sets CONTENT_VALIDATION_ERROR global variable with error message if validation fails
validate_changelog_content() {
    local file_path="$1"
    local head_sha="$2"
    CONTENT_VALIDATION_ERROR=""

    log_info "Validating changelog content format for ${file_path}..."

    # Fetch file content from GitHub API
    local content_response=$(curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3.raw" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${file_path}?ref=${head_sha}")

    if [[ -z "${content_response}" ]]; then
        log_error "Failed to fetch changelog file content"
        CONTENT_VALIDATION_ERROR="Could not fetch changelog file content from GitHub"
        return 1
    fi

    # Write content to temp file
    local temp_file=$(mktemp)
    echo "${content_response}" > "${temp_file}"

    # Validate using cog verify
    log_info "Running conventional commits validation..."
    local cog_output
    if cog_output=$(cog verify --file "${temp_file}" 2>&1); then
        log_info "Changelog content follows conventional commits format"
        rm -f "${temp_file}"
        return 0
    else
        log_error "Changelog content does not follow conventional commits format"
        CONTENT_VALIDATION_ERROR="${cog_output}"
        rm -f "${temp_file}"
        return 1
    fi
}


# Add review comment to PR
add_review_comment() {
    local pr_number=$1
    local body="$2"
    local event="$3"

    log_info "Adding review comment to PR #${pr_number}..."

    # Create the review payload
    local review_payload=$(jq -n \
        --arg body "$body" \
        --arg event "$event" \
        '{
            body: $body,
            event: $event
        }')

    # Submit the review using GitHub API
    local response=$(curl -s -w "%{http_code}" \
        -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$review_payload" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews")

    local http_code="${response: -3}"
    local response_body="${response%???}"

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        log_info "Successfully added review comment"
    else
        log_error "Failed to add review comment. HTTP code: $http_code"
        log_error "Response: $response_body"
    fi
}

# Generate review comment based on validation results
generate_review_comment() {
    local changelog_found="$1"
    local content_valid="$2"
    local content_error="$3"

    local comment_body=""
    local review_event=""

    if [[ "$changelog_found" == "true" && "$content_valid" == "true" ]]; then
        # All checks passed
        comment_body="## ✅ Changelog Validation Passed

All required data for the changelog validation checks have passed:

- ✅ **Changelog file found** - Changes are documented
- ✅ **Content format valid** - Follows conventional commits specification

This PR is ready for review! 🚀"
        review_event="COMMENT"
    else
        # Some checks failed
        comment_body="## ❌ Changelog Validation Failed

The following issues were found with this PR:

"
        if [[ "$changelog_found" != "true" ]]; then
            comment_body+="- ❌ **Missing changelog file**
  - Please add a changelog file to the \`.changelog/\` directory
  - Name it descriptively (e.g., \`fix-bug-123.md\`, \`add-new-feature.md\`)
  - The content must follow conventional commits format

"
        else
            comment_body+="- ✅ **Changelog file found**

"
        fi

        if [[ "$changelog_found" == "true" && "$content_valid" != "true" ]]; then
            comment_body+="- ❌ **Invalid changelog content format**
  - The changelog content must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification
  - Error: \`${content_error}\`

  **Valid format examples:**
  \`\`\`
  feat: add user authentication
  fix: resolve login timeout issue
  feat(api): add new endpoint for user profiles
  fix(ui): correct button alignment on mobile
  feat!: redesign authentication flow (breaking change)
  \`\`\`

"
        elif [[ "$changelog_found" == "true" ]]; then
            comment_body+="- ✅ **Content format valid**

"
        fi

        comment_body+="Please fix the issues above and push your changes. The validation will run again automatically."
        review_event="REQUEST_CHANGES"
    fi

    echo "$comment_body|$review_event"
}

# Main validation function
main() {
    log_info "Starting PR data validation..."

    # Check if we're in the right context
    check_pr_context

    # Get PR number and head SHA
    PR_NUMBER=$(get_pr_number)
    PR_HEAD_SHA=$(get_pr_head_sha)
    log_info "Validating PR #${PR_NUMBER} (HEAD: ${PR_HEAD_SHA})"

    # Get changed files
    CHANGED_FILES=$(get_changed_files "${PR_NUMBER}")
    log_info "Changed files in PR:"
    echo "${CHANGED_FILES}"
    if [[ -z "${CHANGED_FILES}" ]]; then
        log_warn "No files changed in this PR"
        return 0
    fi

    # Check for changelog file
    changelog_found=false
    content_valid=false
    if check_changelog_file "${CHANGED_FILES}"; then
        changelog_found=true

        # Validate changelog content format
        if validate_changelog_content "${CHANGELOG_FILE}" "${PR_HEAD_SHA}"; then
            content_valid=true
        fi
    fi

    # Generate review comment
    REVIEW_COMMENT=$(generate_review_comment "${changelog_found}" "${content_valid}" "${CONTENT_VALIDATION_ERROR}")
    COMMENT_BODY="${REVIEW_COMMENT%|*}"
    REVIEW_EVENT="${REVIEW_COMMENT#*|}"

    # Add review comment to PR
    add_review_comment "${PR_NUMBER}" "${COMMENT_BODY}" "${REVIEW_EVENT}"

    # Set outputs
    echo "changelog-found=${changelog_found}" >> $GITHUB_OUTPUT
    echo "changelog-valid=${content_valid}" >> $GITHUB_OUTPUT

    # Final validation result
    if [[ "${changelog_found}" == "true" && "${content_valid}" == "true" ]]; then
        log_info "✅ All PR data validation checks passed!"
        exit 0
    else
        log_error "❌ PR data validation failed"
        echo ""
        echo "Please fix the issues above and push your changes."
        exit 1
    fi
}

# Run main function
main "$@"
