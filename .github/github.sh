retry() {
  local output errors code
  output=$(mktemp)
  errors=$(mktemp)
  until "$@" > "$output" 2> "$errors"; do
    code=$?
    cat "$errors" >&2
    # gh reports a 5xx with an empty JSON body as "unexpected end of JSON input".
    # uploads.github.com can answer 404 for a release that exists during an outage.
    grep -qE 'HTTP 5[0-9]{2}|unexpected end of JSON input|returned error: 5[0-9]{2}|Internal Server Error|fatal error in commit_refs|HTTP 404: Not Found \(https://uploads\.github\.com/' "$errors" || return "$code"
    sleep 10
  done
  cat "$output"
  cat "$errors" >&2
}

delete() {
  local errors
  errors=$(gh api -X DELETE "$1" 2>&1 > /dev/null) && return
  [[ "$errors" == *"HTTP 404"* ]] && return
  echo "$errors" >&2
  return 1
}

# gh release view and download report a 5xx as "release not found", so look releases up with gh api.
drafts() {
  gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq ".[] | select(.draft and .tag_name == \"$1\") | .url"
}

create_draft() {
  local tag=$1 stale draft
  stale=$(drafts "$tag") || return
  for draft in $stale; do
    delete "$draft" || return
  done
  gh release create "$tag" --draft "${@:2}" > /dev/null || return
  drafts "$tag"
}
