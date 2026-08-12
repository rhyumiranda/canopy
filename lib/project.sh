# project.sh — project registry (read layer). Sourced, not executed.
# shellcheck shell=bash
#
# The registry IS the folder: any git repo directly under <canopy-repo>/projects/
# is a registered project (name = dir basename). One orchestrator can then resolve
# a project by name and route work to it, instead of one Canopy session per repo.
#
# These commands operate on projects/ under repo_root() and MUST NOT call
# require_canopy — the canopy repo itself may have no .canopy/, and a project is
# valid the moment it is a git repo under projects/, with or without its own board.

# Absolute path to the projects/ registry dir (may not exist yet).
_projects_root() { echo "$(repo_root)/projects"; }

# _home_root — absolute path to the orchestrator HOME repo (the one whose
# projects/ registry holds routed projects). If the current repo sits directly
# under a <home>/projects/ dir, that <home> is the home; otherwise the current
# repo is its own home (single-repo use, or the canopy home itself). Lets the
# session-wide global mode be resolved regardless of which project the
# orchestrator has cd'd into.
_home_root() {
  local root parent home
  root="$(repo_root)"
  parent="$(dirname "$root")"
  if [ "$(basename "$parent")" = "projects" ]; then
    home="$(dirname "$parent")"
    [ -e "$home/.git" ] && { printf '%s\n' "$home"; return 0; }
  fi
  printf '%s\n' "$root"
}

# _project_repos — print, one absolute path per line, each immediate subdir of
# projects/ that is its own git repo (has a .git dir or file). Prints nothing
# when projects/ is absent or holds no repos (callers handle the empty case).
_project_repos() {
  local root d
  root="$(_projects_root)"
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue   # no glob match -> literal pattern, skip
    d="${d%/}"                # strip trailing slash
    [ -e "$d/.git" ] || continue
    printf '%s\n' "$d"
  done
}

# canopy project ls — list registered projects with abs path and in-flight count.
canopy_project_ls() {
  need git
  local root repos=() d
  root="$(_projects_root)"
  while IFS= read -r d; do
    [ -n "$d" ] && repos+=("$d")
  done < <(_project_repos)

  if [ "${#repos[@]}" -eq 0 ]; then
    info "no projects registered — add a git repo under $root/ (each subdir that is its own git repo becomes a project)"
    return 0
  fi

  local name sf count
  for d in ${repos[@]+"${repos[@]}"}; do
    name="$(basename "$d")"
    sf="$d/.canopy/state.json"
    count=""
    if [ -f "$sf" ]; then
      count="$(jq '[.tasks[] | select(.status != "done")] | length' "$sf" 2>/dev/null)" || count=""
    fi
    if [ -n "$count" ]; then
      printf '%s\t%s\t%s in-flight\n' "$name" "$d" "$count"
    else
      printf '%s\t%s\n' "$name" "$d"
    fi
  done
}

# canopy project path <name> — resolve a project name to its absolute path.
# Exact basename match wins; else a UNIQUE case-insensitive substring match.
# Zero matches or ambiguity die loudly, listing the candidate names.
canopy_project_path() {
  need git
  local name="${1:-}"
  [ -n "$name" ] || die "usage: canopy project path <name>"
  local root
  root="$(_projects_root)"

  # Exact basename match wins outright.
  if [ -e "$root/$name/.git" ]; then
    printf '%s\n' "$root/$name"
    return 0
  fi

  local repos=() d
  while IFS= read -r d; do
    [ -n "$d" ] && repos+=("$d")
  done < <(_project_repos)

  # Case-insensitive substring match against each basename.
  local lname matches=() b lb
  lname="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  for d in ${repos[@]+"${repos[@]}"}; do
    b="$(basename "$d")"
    lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
    case "$lb" in
      *"$lname"*) matches+=("$d") ;;
    esac
  done

  local n="${#matches[@]}" names=""
  if [ "$n" -eq 0 ]; then
    for d in ${repos[@]+"${repos[@]}"}; do names="$names $(basename "$d")"; done
    die "no project matches '$name'. Known projects:${names:- (none)}"
  fi
  if [ "$n" -gt 1 ]; then
    for d in ${matches[@]+"${matches[@]}"}; do names="$names $(basename "$d")"; done
    die "'$name' is ambiguous — matches:${names}. Use a more specific name."
  fi
  printf '%s\n' "${matches[0]}"
}
