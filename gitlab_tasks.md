Following is CHAT output from CHAT GPT 5.

Plan, think and propose me how to add this feature?
No action now.



Perfect 🚀 You’ve got your repo automation working! Here’s a clean **README.md** for your `create_repo.sh`, plus a one-liner snippet for your `justfile`.

---

## 📄 README.md (for `create_repo.sh`)

````markdown
# create_repo.sh

Automates GitLab project creation and local repo bootstrap.

## Features
- Creates (or deletes & recreates) a GitLab repo via API.
- Pushes a minimal **main** branch with:
  - `README.md` showing **PIPELINE** and **REVISION** (from ENV file).
  - Big-file safe `.gitignore` for Nextflow and genomics data.
- Creates a branch named **${REVISION}** with the full pipeline sources.
- Supports reusing repo names with `--delete-existing`.

## Usage
```bash
./create_repo.sh <repo_name> [visibility] [group_id] <SRC_DIR> <DST_DIR> [ENV_FILE] [--delete-existing]
````

### Example

```bash
# ENV file should define PIPELINE and REVISION
PIPELINE=sarek
REVISION=3.4.4
export GITLAB_PAT=xxxxxxx

./create_repo.sh sarek public 2 "$HOME/offline/sarek/sarek" "$HOME/git/sarek" "$HOME/ENV" --delete-existing
```

Result:

* `main` → only README + .gitignore
* `${REVISION}` branch → full pipeline synced from `$SRC_DIR`

## Requirements

* bash, curl, jq, git, rsync
* GitLab Personal Access Token (`GITLAB_PAT`) with `api` scope

````

---

## ⚡ justfile (one-liner task)
In your `justfile`, add:

```just
create-repo repo src dst:
    ./create_repo.sh {{repo}} public 2 {{src}} {{dst}} $HOME/ENV --delete-existing
````

👉 Usage:

```bash
just create-repo sarek "$HOME/offline/sarek/sarek" "$HOME/git/sarek"
```

This wraps your script in a single `just` recipe for quick reuse.

---

