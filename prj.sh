#!/usr/bin/env bash
# proj - fzf-powered project launcher
# Requires: fzf, gum, git

PROJ_PATH="${PROJ_PATH:-${HOME}/projets}"

# === Helpers ===
unique_name() {
  local base="$1"
  local candidate="$base"
  local i=2
  while [[ -d "$PROJ_PATH/$candidate" ]]; do
    candidate="${base}-$i"
    ((i++))
  done
  echo "$candidate"
}

# Depending of the OS, stat has different syntax. 
# This function abstracts that away and returns the most recent modification epoch for a project dir (considering .git if present).
if stat --version >/dev/null 2>&1; then
  get_modified_epoch() {
    local dir="$1"
    if [[ -d "$dir/.git" ]]; then
      stat -c %Y "$dir/.git/refs" "$dir/.git/COMMIT_EDITMSG" 2>/dev/null | sort -rn | head -n1
    else
      stat -c %Y "$dir" 2>/dev/null
    fi
  }
else
  get_modified_epoch() {
    local dir="$1"
    if [[ -d "$dir/.git" ]]; then
      stat -f %m "$dir/.git/refs" "$dir/.git/COMMIT_EDITMSG" 2>/dev/null | sort -rn | head -n1
    else
      stat -f %m "$dir" 2>/dev/null
    fi
  }
fi

epoch_to_age() {
  local mod_epoch="$1"
  local epoch_now diff
  epoch_now=$(date +%s)
  diff=$(((epoch_now - mod_epoch) / 86400))
  if ((diff < 1)); then
    echo "today"
  elif ((diff < 7)); then
    echo "${diff}d ago"
  elif ((diff < 30)); then
    echo "$((diff / 7))w ago"
  elif ((diff < 365)); then
    echo "$((diff / 30))mo ago"
  else
    echo "$((diff / 365))y ago"
  fi
}

# Returns the list of project dirs to show.
# If a dir contains only subdirs (no files), expand it one level.
collect_projects() {
  local full subdirs
  while IFS= read -r full; do
    [[ -z "$full" ]] && continue
    if find "$full" -mindepth 1 -maxdepth 1 -type f -not -name '.*' 2>/dev/null | grep -q .; then
      echo "$full"
    else
      subdirs=$(find "$full" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
      if [[ -n "$subdirs" ]]; then
        echo "$subdirs"
      else
        echo "$full"
      fi
    fi
  done < <(find "$PROJ_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# === Check projects dir exists ===
check_proj_path() {
  if [[ ! -d "$PROJ_PATH" ]]; then
    echo "❌ Projects directory not found: $PROJ_PATH"
    echo "   Create it manually or set PROJ_PATH to an existing directory."
    return 1
  fi
}

# === Run action on a project ===
run_action() {
  local action="$1"
  local full_path="$2"

  case "$action" in
  cd)
    echo "$full_path"
    exit 0
    ;;
  open)
    open "$full_path" 2>/dev/null || xdg-open "$full_path" 2>/dev/null || echo "❌ 'open' command not available."
    exit 2
    ;;
  code)
    code "$full_path" 2>/dev/null || echo "❌ 'code' command not found."
    exit 2
    ;;
  opencode)
    opencode "$full_path" 2>/dev/null || echo "❌ 'opencode' command not found."
    exit 2
    ;;
  claude)
    claude "$full_path" 2>/dev/null || echo "❌ 'claude' command not found."
    exit 2
    ;;
  esac
}

# === Main selector (fzf-based) ===
selector() {
  check_proj_path || return 1

  local query="${1:-}"

  # Detect if query looks like a Git URL and auto-clone
  if [[ -n "$query" ]] && [[ "$query" =~ ^(https?://|git@|ssh://) || "$query" =~ \.git$ ]]; then
    cmd_clone "$query"
    return
  fi

  local epoch_now mod_epoch full dir age entry
  epoch_now=$(date +%s)

  # Build list sorted by modification date descending
  local tmp_list=()
  while IFS= read -r full; do
    [[ -z "$full" ]] && continue
    mod_epoch=$(get_modified_epoch "$full")
    tmp_list+=("${mod_epoch} ${full}")
  done < <(collect_projects)

  IFS=$'\n' sorted=($(printf '%s\n' "${tmp_list[@]}" | sort -rn))
  unset IFS

  local choices=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    mod_epoch="${entry%% *}"
    full="${entry#* }"
    dir="${full#$PROJ_PATH/}"

    # Filter by query
    if [[ -n "$query" ]] && [[ "$dir" != *"$query"* ]]; then
      continue
    fi

    age=$(epoch_to_age "$mod_epoch")
    choices+=("$(printf "%s\t%-40s  %s" "$full" "$dir" "$age")")
  done < <(printf '%s\n' "${sorted[@]}")

  if [[ ${#choices[@]} -eq 0 ]] && [[ -z "$query" ]]; then
    echo "📂 No projects found in $PROJ_PATH"
    return 1
  fi

  # autojump-style: with a query, jump directly to the first (most recent) match
  if [[ -n "$query" ]] && [[ ${#choices[@]} -gt 0 ]]; then
    local first_path
    first_path=$(echo "${choices[0]}" | cut -f1)
    run_action cd "$first_path"
    return
  fi

  choices+=("NEW	+ New project	")

  local user_selection
  user_selection=$(printf "%s\n" "${choices[@]}" |
    fzf --ansi --reverse --height=30 \
      --with-nth=2.. \
      --delimiter=$'\t' \
      --prompt="Select a project: " \
      --header="$(printf '%d projects in %s' "$((${#choices[@]} - 1))" "$PROJ_PATH")" \
      --footer="Enter: cd  |  Ctrl-O: open  |  Ctrl-E: opencode  |  Ctrl-A: claude  |  Ctrl-N: new" \
      --expect=enter,ctrl-o,ctrl-e,ctrl-a,ctrl-n \
      --query="$query" \
      --preview='[[ -d {1} ]] && ls --color=always -lAh --group-directories-first {1} || echo "(new project)"' \
      --preview-window=down:5:wrap)

  local key selected
  key=$(echo "$user_selection" | head -n1)
  selected=$(echo "$user_selection" | tail -n1)

  [[ -z "$selected" ]] && return 0

  # Handle new project
  if [[ "$key" == "ctrl-n" ]] || [[ "$selected" == NEW* ]]; then
    cmd_new "$query"
    return
  fi

  local full_path
  full_path=$(echo "$selected" | cut -f1)

  case "$key" in
  enter) run_action cd "$full_path" ;;
  ctrl-o) run_action open "$full_path" ;;
ctrl-e) run_action opencode "$full_path" ;;
  ctrl-a) run_action claude "$full_path" ;;
  esac
}

# === Create new project ===
cmd_new() {
  check_proj_path || return 1

  local suggested="${1:-}"
  local name

  if [[ -n "$suggested" ]]; then
    name="$suggested"
  else
    name=$(gum input --placeholder "e.g. my-new-project" --prompt "Project name: ")
    [[ -z "$name" ]] && return 1
  fi

  local base="${name// /-}"
  base="${base//[^a-zA-Z0-9_-]/}"
  base=$(unique_name "$base")

  local dir="$PROJ_PATH/$base"
  mkdir -p "$dir"
  echo "✅ Created $dir" >&2
  echo "$dir"
  exit 0
}

# === Clone repo ===
cmd_clone() {
  check_proj_path || return 1
  [[ $# -eq 0 ]] && echo "Usage: proj clone <uri> [name]" >&2 && return 1

  local uri="$1"
  local custom="${2:-}"
  local name

  if [[ -n "$custom" ]]; then
    name="${custom// /-}"
  else
    name=$(basename "$uri" .git)
    name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  fi

  name=$(unique_name "$name")
  local target="$PROJ_PATH/$name"

  if ! command -v git >/dev/null 2>&1; then
    echo "❌ git command not found. Please install Git." >&2
    return 1
  fi

  echo "📦 Cloning $uri → $target..." >&2
  git clone "$uri" "$target" >&2 && echo "$target" && exit 0
}

# === List projects ===
cmd_list() {
  check_proj_path || return 1

  if [[ -z "$(collect_projects)" ]]; then
    echo "📂 No projects found in $PROJ_PATH"
    return
  fi

  echo
  echo "📂 Projects in $PROJ_PATH  (sorted by last modification)"
  echo

  local tmp_list=()
  local full mod_epoch
  while IFS= read -r full; do
    [[ -z "$full" ]] && continue
    mod_epoch=$(get_modified_epoch "$full")
    tmp_list+=("${mod_epoch} ${full}")
  done < <(collect_projects)

  IFS=$'\n' sorted=($(printf '%s\n' "${tmp_list[@]}" | sort -rn))
  unset IFS

  local entry dir age
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    mod_epoch="${entry%% *}"
    full="${entry#* }"
    dir="${full#$PROJ_PATH/}"
    age=$(epoch_to_age "$mod_epoch")
    printf "  %-35s  %s\n" "$dir" "$age"
  done < <(printf '%s\n' "${sorted[@]}")
}

# === Init (for zshrc/bashrc) ===
cmd_init() {
  local script_path
  script_path="$(realpath "${BASH_SOURCE[0]}")"

  cat <<EOF
# >>> proj initialization >>>
export PROJ_PATH="$PROJ_PATH"
proj() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "proj requires fzf. Please install fzf."
    return 0
  fi
  if ! command -v gum >/dev/null 2>&1; then
    echo "proj requires gum. Please install gum."
    return 0
  fi
  local result
  result=\$(bash "$script_path" "\$@")
  local exit_code=\$?
  if [[ \$exit_code -eq 0 && -n "\$result" && -d "\$result" ]]; then
    cd "\$result"
  fi
}
# <<< proj initialization <<<
EOF
}

# === Help ===
cmd_help() {
  cat <<'EOF'
  proj - fzf-powered project launcher

  USAGE:
    proj                        # Open project selector
    proj <query>                # Jump to first matching project (autojump-style)
    proj <git-url>              # Clone a git repo directly
    proj new [name]             # Create a new project folder
    proj clone <uri> [name]     # Clone a git repo (explicit)
    proj list|ls                # List all projects
    proj init                   # Print shell init code (use with eval)
    proj -h|--help|help         # Show this help

  ACTIONS (keyboard shortcuts in the selector):
    Enter      → cd into the project directory
    Ctrl-O     → open directory (Finder / file manager)
    Ctrl-E     → open with opencode
    Ctrl-A     → open with claude
    Ctrl-N     → create a new project

  SETUP:
    Add to your .zshrc / .bashrc:
      eval "$(~/.local/bin/proj init)"

  TIPS:
    • PROJ_PATH env var overrides the default ~/projects directory
    • Folders with only subfolders (no files) are expanded one level
EOF
}

# === Main entry point ===
_proj_main() {
  local cmd="${1:-}"
  shift 2>/dev/null || true

  case "$cmd" in
  "") selector ;;
  new) cmd_new "$@" ;;
  clone) cmd_clone "$@" ;;
  list | ls) cmd_list ;;
  init) cmd_init ;;
  -h | --help | help) cmd_help ;;
  *) selector "$cmd" ;;
  esac
}

_proj_main "$@"
