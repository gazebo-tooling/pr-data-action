#!/bin/bash
# Validate the changelog entries of a pull request.
#
# Every file added, modified or renamed under CHANGELOG_DIR is an entry, except
# hidden files and files inside hidden directories (e.g. the .gitkeep that
# keeps the directory). Removed files are ignored: the release commit removes
# the entries it processed.
#
# The entry rules mirror create_changelog_entry.py (gazebo-tooling/release-tools),
# which turns the entries into Changelog.md at release time, so an entry that
# passes here can be released.
#
# Results go to the job log, the job summary and error annotations. The script
# only reads from the GitHub API, so the read-only token of fork PRs is enough.
set -euo pipefail

# Byte-wise matching: [a-z] must not match uppercase letters in some locales
export LC_ALL=C

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CHANGELOG_DIR="${CHANGELOG_DIR:-.changelog}"
CHANGELOG_DIR="${CHANGELOG_DIR%/}"
SKIP_LABEL="${SKIP_LABEL:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# CONVENTIONAL_COMMIT_HEADER_RE of create_changelog_entry.py. Group 2 is the
# breaking marker '!'.
HEADER_RE='^[a-z]+(\([^()]+\))?(!)?: [^[:space:]]'
# Conventional Commits breaking change footer
BREAKING_FOOTER_RE='^BREAKING[ -]CHANGE(: | #)'

# Helper functions. The message is printed as is (%s): it can contain file
# names from the PR, and expanding their escapes (echo -e) could print a new
# line that GitHub runs as a workflow command.
log_info() {
  printf '%b[INFO]%b %s\n' "${GREEN}" "${NC}" "$1"
}

log_warn() {
  printf '%b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$1"
}

log_error() {
  printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$1"
}

# Print text that comes from the pull request (entry content, cog output)
# without letting GitHub run workflow commands (lines like '::error::') in it.
print_untrusted() {
  local token="untrusted-${RANDOM}${RANDOM}${RANDOM}"
  echo "::stop-commands::${token}"
  printf '%s\n' "$1"
  echo "::${token}::"
}

escape_data() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "${s}"
}

escape_property() {
  local s
  s=$(escape_data "$1")
  s="${s//':'/'%3A'}"
  s="${s//','/'%2C'}"
  printf '%s' "${s}"
}

# Error annotation, shown in the checks UI and, with a file, in the diff
annotate_error() {
  local file="$1"
  local title="$2"
  local message="$3"
  local properties
  properties="title=$(escape_property "${title}")"

  if [[ -n "${file}" ]]; then
    properties="file=$(escape_property "${file}"),line=1,${properties}"
  fi
  echo "::error ${properties}::$(escape_data "${message}")"
}

# Markdown code block that the content can't break out of
indent_block() {
  sed 's/^/    /' <<<"$1"
}

summary() {
  printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY}"
}

set_outputs() {
  echo "changelog-found=$1" >>"${GITHUB_OUTPUT}"
  echo "changelog-valid=$2" >>"${GITHUB_OUTPUT}"
}

# Check if we're in a pull request context
check_pr_context() {
  if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
    log_error "This action should only run on pull request events"
    exit 1
  fi
  if [[ ! -f "${GITHUB_EVENT_PATH:-}" ]]; then
    log_error "GITHUB_EVENT_PATH is not set or file does not exist"
    exit 1
  fi
}

# GET a GitHub API URL and print the response body. Fails on HTTP errors.
api_get() {
  local url="$1"
  local accept="${2:-application/vnd.github+json}"
  local -a headers=(-H "Accept: ${accept}" -H "X-GitHub-Api-Version: 2022-11-28")

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 3 "${headers[@]}" "${url}"
}

# Print the files of the PR as JSON lines {filename, status, contents_url}.
# The API returns 100 files per page at most, so read every page.
get_pr_files() {
  local pr_number="$1"
  local page=1
  local response

  while true; do
    response=$(api_get "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/files?per_page=100&page=${page}") || return 1
    jq -c '.[] | {filename, status, contents_url}' <<<"${response}" || return 1
    if [[ $(jq 'length' <<<"${response}") -lt 100 ]]; then
      return 0
    fi
    page=$((page + 1))
  done
}

# Read PR file JSON lines on stdin and print "<path>\t<contents_url>" for each
# changelog entry (see the top of the file for what counts as an entry).
select_entries() {
  jq -r --arg dir "${CHANGELOG_DIR}/" '
    select(.status != "removed")
    | select(.filename | startswith($dir))
    | select(.filename | ltrimstr($dir) | split("/") | any(startswith(".")) | not)
    | [.filename, .contents_url] | @tsv'
}

# Print the entry the way create_changelog_entry.py reads it: universal
# newlines, template comment lines ('# ...') removed, no leading or trailing
# blank lines.
normalize_entry() {
  sed 's/\r$//' | tr '\r' '\n' | sed -E '/^[[:space:]]*#([[:space:]]|$)/d' | awk '
    NF {
      if (!started) sub(/^[[:space:]]+/, "")
      started = 1
      for (; blanks > 0; blanks--) print ""
      print
      next
    }
    started { blanks++ }'
}

# Check a normalized entry. On failure print the reason and return 1.
check_entry() {
  local content="$1"
  local header
  local cog_input
  local cog_output

  if [[ -z "${content}" ]]; then
    echo "The entry is empty (lines starting with '# ' are comments)."
    return 1
  fi

  header=$(head -n 1 <<<"${content}")
  header="${header%"${header##*[![:space:]]}"}"
  if [[ ! "${header}" =~ ${HEADER_RE} ]]; then
    echo "The first line must be '<type>(<optional scope>): <description>', got:"
    echo "${header}"
    return 1
  fi

  if [[ -n "${BASH_REMATCH[2]}" ]] || grep -Eq "${BREAKING_FOOTER_RE}" <<<"${content}"; then
    echo "Breaking changes ('!' after the type or a 'BREAKING CHANGE:' footer)"
    echo "are not supported by automatic releases. Ask a maintainer."
    return 1
  fi

  cog_input=$(mktemp)
  printf '%s\n' "${content}" >"${cog_input}"
  if ! cog_output=$(cog verify --file "${cog_input}" 2>&1); then
    rm -f "${cog_input}"
    echo "The entry does not follow Conventional Commits (cog verify):"
    echo "${cog_output}"
    return 1
  fi
  rm -f "${cog_input}"
}

how_to_summary() {
  summary "### How to write a changelog entry" \
    "" \
    "Add a file to \`${CHANGELOG_DIR}/\` named after the change (e.g. \`fix-discovery-crash.md\`)." \
    "Its first line follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#summary):" \
    "\`<type>(<optional scope>): <description>\`. Lines below it are the body of the entry," \
    "and lines starting with \`# \` are comments." \
    "" \
    "    fix: resolve a crash in discovery when the network goes down" \
    "" \
    "A \`feat\` entry bumps the minor version at release time; other types bump the patch version." \
    "Breaking changes (\`feat!:\` or a \`BREAKING CHANGE:\` footer) are released manually: ask a maintainer." \
    ""
  if [[ -n "${SKIP_LABEL}" ]]; then
    summary "If this pull request needs no entry (e.g. a forward port or a release)," \
      "a maintainer can add the \`${SKIP_LABEL}\` label." \
      ""
  fi
}

# Main validation function
main() {
  local pr_number
  local files
  local entries
  local path
  local url
  local raw
  local reason
  local i
  local -a valid_entries=()
  local -a invalid_entries=()
  local -a invalid_reasons=()

  log_info "Starting PR data validation..."
  check_pr_context

  pr_number=$(jq -r '.pull_request.number' "${GITHUB_EVENT_PATH}")
  if [[ -z "${pr_number}" || "${pr_number}" == "null" ]]; then
    log_error "Could not extract PR number from event data"
    exit 1
  fi
  log_info "Validating PR #${pr_number} (HEAD: $(jq -r '.pull_request.head.sha' "${GITHUB_EVENT_PATH}"))"

  if [[ -n "${SKIP_LABEL}" ]] &&
    jq -e --arg label "${SKIP_LABEL}" \
      'any(.pull_request.labels[]?; .name == $label)' "${GITHUB_EVENT_PATH}" >/dev/null; then
    log_info "The PR has the '${SKIP_LABEL}' label: skipping the changelog check"
    summary "## ⏭️ Changelog check skipped" "" \
      "This pull request has the \`${SKIP_LABEL}\` label."
    set_outputs false false
    exit 0
  fi

  if ! files=$(get_pr_files "${pr_number}"); then
    log_error "Could not get the list of files of PR #${pr_number} from GitHub"
    annotate_error "" "Changelog check error" \
      "Could not get the list of files of the pull request from GitHub. Re-run the job."
    exit 1
  fi
  if [[ -z "${files}" ]]; then
    log_warn "No files changed in this PR"
    set_outputs false false
    exit 0
  fi

  entries=$(select_entries <<<"${files}")
  if [[ -z "${entries}" ]]; then
    log_error "No changelog entry found in ${CHANGELOG_DIR}/"
    annotate_error "" "Missing changelog entry" \
      "Add a file to ${CHANGELOG_DIR}/ describing the change. See the job summary."
    summary "## ❌ Missing changelog entry" "" \
      "This pull request does not add or modify any file in \`${CHANGELOG_DIR}/\`." ""
    how_to_summary
    set_outputs false false
    exit 1
  fi

  while IFS=$'\t' read -r path url <&3; do
    log_info "Validating ${path}"
    if ! raw=$(api_get "${url}" "application/vnd.github.raw+json"); then
      reason="Could not download the file from GitHub. Re-run the job."
    elif reason=$(check_entry "$(normalize_entry <<<"${raw}")"); then
      log_info "${path} is valid"
      valid_entries+=("${path}")
      continue
    fi
    log_error "${path} is not valid:"
    print_untrusted "${reason}"
    annotate_error "${path}" "Invalid changelog entry" "${reason}"
    invalid_entries+=("${path}")
    invalid_reasons+=("${reason}")
  done 3<<<"${entries}"

  if [[ ${#invalid_entries[@]} -eq 0 ]]; then
    summary "## ✅ Changelog entries are valid" ""
    for path in "${valid_entries[@]}"; do
      summary "- \`${path}\`"
    done
    set_outputs true true
    log_info "✅ All PR data validation checks passed!"
    exit 0
  fi

  summary "## ❌ Invalid changelog entries" ""
  for i in "${!invalid_entries[@]}"; do
    summary "#### \`${invalid_entries[$i]}\`" "" "$(indent_block "${invalid_reasons[$i]}")" ""
  done
  if [[ ${#valid_entries[@]} -gt 0 ]]; then
    summary "Valid entries:" ""
    for path in "${valid_entries[@]}"; do
      summary "- \`${path}\`"
    done
    summary ""
  fi
  how_to_summary
  set_outputs true false
  log_error "❌ PR data validation failed: ${#invalid_entries[@]} invalid changelog entries"
  exit 1
}

# Run main function
main "$@"
