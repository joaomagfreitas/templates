#!/usr/bin/env bash

# Bash script to automate configuring a new GitHub repo using "go-repo" template.
# Generated using ChatGPT.
#
# Usage:
#   name=example go_version=1.24.0 ./new-gh-repo.sh
#
# Environment:
#   github_token  (required)  - GitHub personal access token (repo scope)
#   github_org    (optional)  - GitHub organization to create repo in

set -euo pipefail

# --- inputs ---
: "${name:?Environment variable 'name' must be set (repo name)}"
: "${go_version:?Environment variable 'go_version' must be set}"
: "${github_token:?Environment variable 'github_token' must be set}"

api="https://api.github.com"
auth_header="Authorization: token ${github_token}"
accept_header="Accept: application/vnd.github+json"

# --- determine owner ---
if [[ -n "${github_org:-}" ]]; then
  github_owner="$github_org"
else
  echo "Fetching authenticated user..."
  github_owner=$(curl -sS -H "$auth_header" -H "$accept_header" "$api/user" | jq -r '.login')
  if [[ "$github_owner" == "null" || -z "$github_owner" ]]; then
    echo "Failed to determine authenticated user. Check github_token." >&2
    exit 1
  fi
fi

echo "Creating repo '$name' under '$github_owner'..."

# --- create repository ---
create_payload=$(jq -n \
  --arg name "$name" \
  '{
    name: $name,
    private: false,
    has_issues: false,
    has_projects: false,
    has_wiki: false,
    auto_init: false,
    default_branch: "master"
  }')

if [[ -n "${github_org:-}" ]]; then
  create_url="$api/orgs/$github_org/repos"
else
  create_url="$api/user/repos"
fi

response=$(curl -sS -w "\n%{http_code}" -X POST \
  -H "$auth_header" -H "$accept_header" \
  -d "$create_payload" "$create_url")

body="${response%$'\n'*}"
status="${response##*$'\n'}"

if (( status >= 200 && status < 300 )); then
  html_url=$(jq -r '.html_url' <<<"$body")
  echo "Repository created: $html_url"
else
  echo "Failed to create repository (HTTP $status):"
  echo "$body" | jq .
  exit 1
fi

remote_url="https://github.com/${github_owner}/${name}.git"

# --- prepare and commit source files ---
if [[ ! -d "go-repo" ]]; then
  echo "Directory 'go-repo' not found." >&2
  exit 1
fi

# --- copy source files to temp dir ---
tmp_dir=$(mktemp -d)
cp -r go-repo/. "$tmp_dir"

# --- work on temp dir ---
cd "$tmp_dir"

# --- remove source .git config ---
if [[ -d .git ]]; then
  rm -rf .git
fi

echo "Replacing template variables..."
find . -type f ! -path './.git/*' -print0 | while IFS= read -r -d '' file; do
  sed -i \
    -e "s|{{[[:space:]]*\.name[[:space:]]*}}|$name|g" \
    -e "s|{{[[:space:]]*\.go_version[[:space:]]*}}|$go_version|g" \
    -e "s|{{[[:space:]]*\.go_version|$go_version|g" \
    "$file" || true
done

# --- ensure tools/ files are executable ---
if [[ -d tools ]]; then
  echo "Setting execution permission on tools/*..."
  find tools -type f -print0 | while IFS= read -r -d '' f; do
    chmod +x "$f"
  done
fi

echo "Initializing git repo and pushing to GitHub..."
git init -q
git checkout -b master -q
git add --all
git commit -m "chore: init codebase" >/dev/null 2>&1 || echo "No changes to commit"
git remote add origin "$remote_url"
git push -u origin master >/dev/null 2>&1 || {
  echo "Failed to push to $remote_url" >&2
  exit 1
}
cd ..

# --- update repository settings ---
echo "Updating repository settings..."
update_payload=$(jq -n '{
  allow_squash_merge: true,
  allow_merge_commit: false,
  allow_rebase_merge: false,
  allow_auto_merge: true,
  delete_branch_on_merge: true,
  default_workflow_permissions: "read",
  default_branch: "master"
}')

repo_api="$api/repos/$github_owner/$name"
resp_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH \
  -H "$auth_header" -H "$accept_header" \
  -d "$update_payload" "$repo_api")

if (( resp_code >= 200 && resp_code < 300 )); then
  echo "Repository settings updated."
else
  echo "Failed to update repository settings (HTTP $resp_code)" >&2
fi

# --- branch protection rule ---
echo "Applying branch protection rule (require PR + status check)..."
protection_payload=$(jq -n '{
  required_status_checks: {
    strict: false,
    contexts: ["build-and-release"]
  },
  enforce_admins: false,
  required_pull_request_reviews: {
    required_approving_review_count: 1
  },
  restrictions: null
}')

protection_url="$api/repos/$github_owner/$name/branches/master/protection"
resp_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
  -H "$auth_header" \
  -H "Accept: application/vnd.github.luke-cage-preview+json" \
  -H "Content-Type: application/json" \
  -d "$protection_payload" "$protection_url")

if (( resp_code >= 200 && resp_code < 300 )); then
  echo "Branch protection applied."
else
  echo "Failed to apply branch protection (HTTP $resp_code)" >&2
fi

echo
echo "Repository ready at: https://github.com/$github_owner/$name"
