
#!/usr/bin/env bash
# Usage: ./create_git_repo.sh <repo_name> [visibility] [group_id]
# Example: ./create_git_repo.sh myservice public 2

set -euo pipefail

GITLAB_HOST="${GITLAB_HOST:-100.123.206.229}"  # override with env GITLAB_HOST
VISIBILITY="${2:-private}"              # private | internal | public
GROUP_ID="${3:-2}"                      # default to 2 if not given
REPO_NAME="${1:-}"; [[ -z $REPO_NAME ]] && { echo "repo_name required"; exit 1; }
: "${GITLAB_PAT:?Set GITLAB_PAT with your PAT}"

echo ">> Creating $REPO_NAME ($VISIBILITY) in group $GROUP_ID…"
proj_json=$(curl -sS -H "PRIVATE-TOKEN: $GITLAB_PAT" -X POST \
  "http://$GITLAB_HOST/api/v4/projects?name=$REPO_NAME&namespace_id=$GROUP_ID&visibility=$VISIBILITY")

http_url=$(echo "$proj_json" | jq -r .http_url_to_repo)
[[ "$http_url" == "null" ]] && { echo "Creation failed:"; echo "$proj_json"; exit 1; }

echo ">> Repo URL: $http_url"

# Initialise and push if no .git yet
if [[ ! -d .git ]]; then
  git init -q && echo "# $REPO_NAME" > README.md
  git add README.md && git commit -qm "initial commit"
fi

token_url="${http_url/\/\//\/\/gitlab:$GITLAB_PAT@}"
git remote add origin "$token_url" 2>/dev/null || git remote set-url origin "$token_url"
git push -u origin "$(git symbolic-ref --short HEAD)"

echo "✅  Pushed to $http_url"

