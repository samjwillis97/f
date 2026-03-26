#!/bin/sh

# root dir will be $HOME/code
# default git domain will be github.com
dir=$HOME/code
gitDomain=github.com

# TODO: Overrides for these
tmuxPath=$(which tmux)
gitPath=$(which git)

withFzf=true
withPreview=true
printPathOnly=false
ensureWorkspace=false

currentRepoRootPath=""

usage() {
  echo "usage: $0 [-r <root directory>] [-g <git domain>] [-p] [-e] <owner>/<repo>/<branch>" 1>&2; 
  echo "       $0 gc [days]" 1>&2; 
  echo "       $0 clean <days>" 1>&2; 
  echo "" 1>&2;
  echo "flags:" 1>&2; 
  echo "  -h                  display this usage" 1>&2; 
  echo "  -l                  list all of the available workspaces via. fzf" 1>&2; 
  echo "  -L                  list all of the available workspaces without fzf" 1>&2; 
  echo "  -d                  delete a particular workspace" 1>&2; 
  echo "  -p                  print path only (don't create/attach tmux session)" 1>&2; 
  echo "  -e                  ensure workspace exists, print path, and never start tmux" 1>&2; 
  echo "" 1>&2;
  echo "subcommands:" 1>&2; 
  echo "  gc [days]           list stale worktrees (default: 30 days)" 1>&2; 
  echo "  clean <days>        remove worktrees not touched in <days> days" 1>&2; 
  exit 1;
}

get_system() {
  unameOut="$(uname -s)"
  case "${unameOut}" in
      Linux*)     machine=Linux;;
      Darwin*)    machine=Mac;;
      *)          exit 1;;
  esac
  echo ${machine}
}

get_thread_count() {
  if [ "$(get_system)" = "Mac" ]; then
    sysctl -n hw.physicalcpu
  else
    nproc
  fi
}

# create_or_attach_to_tmux_session <session_name> <working_directory>
create_or_attach_to_tmux_session() {
  if $printPathOnly; then
    echo "$2"
    exit 0
  fi

  tmux_running=$(pgrep "$tmuxPath")

  if [ -z "$TMUX" ] && [ -z "$tmux_running" ]; then
      tmux new-session -s "$1" -c "$2"
      exit 0
  fi

  if ! tmux has-session -t="$1" 2> /dev/null; then
      tmux new-session -ds "$1" -c "$2"
  fi

  if [ -z "$TMUX" ]; then
      tmux attach-session -t "$1"
      exit 0
  fi

  tmux switch-client -t "$1"
  exit 0;
}

# get_last_number_of_slugs <path> <number>
get_last_number_of_slugs() {
  echo "$1" | rev | cut -d'/' "-f1-$2" | rev | tr '/' '/'
}

# find_matching_branch_dirs <repo> <branch>
find_matching_branch_dirs() {
  find "$dir" -mindepth 4 -maxdepth 4 -type d -name "$2" -path "$dir/$gitDomain/*/$1/$2"
}

# find_matching_repo_dirs <repo>
find_matching_repo_dirs() {
  find "$dir" -mindepth 3 -maxdepth 3 -type d -name "$1" -path "$dir/$gitDomain/*/$1"
}

# get_local_branch_directories
get_local_branch_directories() {
  local_dirs=($(find "$currentRepoRootPath" -type d -mindepth 1 -maxdepth 1))
  mapped_branches=()

  for item in "${local_dirs[@]}"; do
    branch_name=$(basename "$item")
    mapped_branches+=("$branch_name")
  done

  echo "${mapped_branches[@]}"
}

# get_remote_head_branch_from_local <.git directory>
get_remote_head_branch_from_local() {
  # FIXME: I think we are passing the wrong directory here
  all_branches=($(git --no-pager --git-dir "$1" branch -r))
  echo "${all_branches[2]}"
}

# get_remote_head_branch_from_remote <owner/repo>
get_remote_head_branch_from_remote() {
  echo "fetching remote head branch for git@$gitDomain:$1.git" 1>&2;
  git ls-remote --symref "git@$gitDomain:$1.git" HEAD | grep '^ref:' | sed 's/^ref: refs\/heads\///' | sed 's/\s*HEAD$//' | xargs
}

# get_remote_branches <.git directory>
get_remote_branch_names() {
  all_branches=($(git --no-pager --git-dir "$1" branch -r))
  trimmed_branches=("${all_branches[@]:2}")

  for i in "${!trimmed_branches[@]}"; do
    trimmed_branches[$i]="${trimmed_branches[$i]#origin/}"
  done

  echo "${trimmed_branches[@]}"
}

# is_primary_worktree <worktree_dir>
# Returns 0 (true) if the directory is the primary clone (has a real .git directory, not a .git file)
is_primary_worktree() {
  [ -d "$1/.git" ]
}

# get_worktree_last_modified_epoch <worktree_dir>
# Returns the epoch timestamp of the most recently modified file in the worktree
# Excludes .git and node_modules directories for performance
# Uses GNU find -printf which works in the Nix environment on both macOS and Linux
get_worktree_last_modified_epoch() {
  find "$1" -not -path "$1/.git/*" -not -path "$1/.git" -not -path "$1/node_modules/*" -not -path "$1/node_modules" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
}

# get_worktree_age_days <worktree_dir>
# Returns the number of days since the worktree was last modified
get_worktree_age_days() {
  last_modified=$(get_worktree_last_modified_epoch "$1")
  if [ -z "$last_modified" ]; then
    echo "unknown"
    return
  fi
  now=$(date +%s)
  diff_seconds=$((now - last_modified))
  echo $((diff_seconds / 86400))
}

# format_age <days>
# Returns a human-readable age string
format_age() {
  if [ "$1" = "unknown" ]; then
    echo "unknown"
    return
  fi
  if [ "$1" -ge 365 ]; then
    years=$((${1} / 365))
    if [ "$years" -eq 1 ]; then
      echo "${years} year"
    else
      echo "${years} years"
    fi
  elif [ "$1" -ge 30 ]; then
    months=$((${1} / 30))
    if [ "$months" -eq 1 ]; then
      echo "${months} month"
    else
      echo "${months} months"
    fi
  else
    if [ "$1" -eq 1 ]; then
      echo "${1} day"
    else
      echo "${1} days"
    fi
  fi
}

# copy_direnv <dir>
enable_direnv() {
  if [ -f "$1/.envrc" ]; then
    direnv allow "$1/.envrc"
  fi
}

# copy_node_modules <from_dir> <to_dir>
copy_node_modules() {
  if [ -d "$1/node_modules" ]; then
    echo "copying node_modules..." 1>&2;
    if [ "$(get_system)" = "Mac" ]; then
      ditto --clone "$1/node_modules" "$2/node_modules"
    else
      cp -r --reflink=auto "$1/node_modules" "$2"
    fi
  fi
}

# copy_untracked_files <from_dir> <to_dir>
copy_untracked_files() {
  count=$(git --git-dir "$1/.git" --work-tree "$1" ls-files --others | grep -v '^node_modules/' | wc -l | xargs)
  echo "$count files to copy..." 1>&2;
  pushd "$1" || exit 1;

  copy_with_structure() {
    local file="$1"
    local dest_base="$2"
    
    # Create directory structure in destination
    dest_dir="$dest_base/$(dirname "$file")"
    mkdir -p "$dest_dir"
    
    # Copy the file preserving path
    if [ "$(get_system)" = "Mac" ]; then
      ditto --clone "$file" "$dest_base/$file"
    else
      cp -P --reflink=auto "$file" "$dest_base/$file"
    fi
  }

  # Export the function so xargs can use it
  export -f copy_with_structure
  export -f get_system

  git --git-dir "$1/.git" --work-tree "$1" ls-files --others | grep -v '^node_modules/' | xargs -P "$(get_thread_count)" -I{} sh -c 'copy_with_structure "$1" "$2"' _ {} "$2"
  popd || exit 1;
}

# checkout_branch <branch_name>
checkout_branch() {
  last_two_slugs=$(get_last_number_of_slugs "$currentRepoRootPath" 2)
  remote_head="$(get_remote_head_branch_from_remote "$last_two_slugs")"

  if [ -z "$remote_head" ]; then
    echo "No remote head branch found for $last_two_slugs" 1>&2;
    exit 1
  fi

  git_directory="$currentRepoRootPath/$remote_head/.git"

  echo "fetching repo $git_directory..." 1>&2;
  git --git-dir "$git_directory" fetch

  branches=($(get_remote_branch_names "$git_directory"))

  found=0
  for val in "${branches[@]}"; do
    if [ "$val" == "$1" ]; then
      found=1
    fi
  done

  branch_directory="$currentRepoRootPath/$1"
  if [ $found -eq 0 ]; then
    echo "checking out new branch..." 1>&2;
    git --git-dir "$git_directory" worktree add -b "$1" "$branch_directory" "$remote_head"
  else
    echo "checkout out existing branch..." 1>&2;
    git --git-dir "$git_directory" worktree add "$branch_directory" "$1"
  fi

  echo "copying untracked files..." 1>&2;
  copy_node_modules "$currentRepoRootPath/${remote_head}" "$branch_directory"
  copy_untracked_files "$currentRepoRootPath/${remote_head}" "$branch_directory"

  echo "enabling direnv..." 1>&2;
  enable_direnv "$branch_directory"

  echo "creating new tmux session..." 1>&2;
  session_name=$(get_last_number_of_slugs "$branch_directory" 3)
  create_or_attach_to_tmux_session "$session_name" "$branch_directory"
}

# clone_repo <repo> -> <branch>
clone_repo() {
  currentRepoRootPath="$dir/$gitDomain/$1"

  echo "going to clone repo..." 1>&2;
  mkdir -p "$currentRepoRootPath"

  echo "fetching remote branch head..." 1>&2;
  remote_head_branch=$(get_remote_head_branch_from_remote "$1")

  echo "cloning repo..."  1>&2;
  git clone "git@$gitDomain:$1.git" "$currentRepoRootPath/$remote_head_branch" &> /dev/null

  echo "$remote_head_branch"
}

# handle_repo_branch_pattern <repo> <branch>
handle_repo_branch_pattern() {
  repo_name=$1
  branch_name=$2

  matching_directories=$(find_matching_branch_dirs "$repo_name" "$branch_name")
  matching_directories_count=$(find_matching_branch_dirs "$repo_name" "$branch_name" | wc -l)

  if [ "$matching_directories_count" -eq 1 ]; then
    echo "Found matching directory for ${repo_name}/${branch_name}: ${matching_directories}" 1>&2;
    session_name=$(get_last_number_of_slugs "$matching_directories" 3)
    create_or_attach_to_tmux_session "$session_name" "$matching_directories"
  elif [ "$matching_directories_count" -eq 0 ]; then
    echo "No matching directories found for $repo_name/$branch_name, attempting to clone..." 1>&2;
    # need to check for the $working_directory/$repo_name existing
    # if not - attempt to clone and checkout the branch
    matching_directories=$(find_matching_repo_dirs "$repo_name")
    matching_directories_count=$(find_matching_repo_dirs "$repo_name" | wc -l)

    if [ "$matching_directories_count" -eq 1 ]; then
      currentRepoRootPath=$matching_directories
      checkout_branch "$branch_name"
    elif [ "$matching_directories_count" -eq 0 ]; then
      main_branch=$(clone_repo "$1/$2")
      create_or_attach_to_tmux_session "$1/$2/$main_branch" "$dir/$gitDomain/$1/$2/$main_branch"
    fi
    exit 1
  fi
  echo "Found ${matching_directories_count} directories matching $repo_name/$branch_name, please be more precise" 1>&2;
  exit 1
}

# handle_owner_repo_branch_pattern <owner> <repo> <branch>
handle_owner_repo_branch_pattern() {
  owner_name=$1
  repo_name=$2
  branch_name=$3

  tmux_session_name="$owner_name/$repo_name/$branch_name"
  branch_directory="$dir/$gitDomain/$owner_name/$repo_name/$branch_name"

  if [ -d "$branch_directory" ]; then
    create_or_attach_to_tmux_session "$tmux_session_name" "$branch_directory"
  fi

  matching_directories=$(find "$dir" -mindepth 3 -maxdepth 3 -type d -name "$repo_name" -path "$dir/$gitDomain/$owner_name/$repo_name")
  matching_directories_count=$(find "$dir" -mindepth 3 -maxdepth 3 -type d -name "$repo_name" -path "$dir/$gitDomain/$owner_name/$repo_name" | wc -l)
  if [ "$matching_directories_count" -eq 1 ]; then
    currentRepoRootPath=$matching_directories
    checkout_branch "$branch_name"
  elif [ "$matching_directories_count" -eq 0 ]; then
    clone_repo "$owner_name/$repo_name" 1>/dev/null
    currentRepoRootPath="$dir/$gitDomain/$owner_name/$repo_name"
    checkout_branch "$branch_name"
  fi
  exit 1
}


# handle_creation <repo>
handle_creation() {
  # check for <repo>/<branch> pattern
  if [[ $1 =~ ^[^/]+/[^/]+$ ]]; then
    repo_name=$(echo "$1" | cut -d'/' -f1)
    branch_name=$(echo "$1" | cut -d'/' -f2)
    echo "Handling ${1} as repo/branch pattern" 1>&2;
    handle_repo_branch_pattern "$repo_name" "$branch_name"
  fi

  # check for <owner>/<repo>/<branch> pattern
  if [[ $1 =~ ^[^/]+/[^/]+/[^/]+$ ]]; then
    owner_name=$(echo "$1" | cut -d'/' -f1)
    repo_name=$(echo "$1" | cut -d'/' -f2)
    branch_name=$(echo "$1" | cut -d'/' -f3)
    echo "Handling ${1} as owner/repo/branch pattern" 1>&2;
    handle_owner_repo_branch_pattern "$owner_name" "$repo_name" "$branch_name"
  fi
}

handle_list() {
  if $withFzf; then
    if $withPreview; then
      selected="$(find "$dir" -mindepth 4 -maxdepth 4 -type d | fzf -i --scheme=path --print-query --preview="git --git-dir={}/.git --no-pager -c color.ui=always show --summary --format=fuller")"
    else
      selected="$(find "$dir" -mindepth 4 -maxdepth 4 -type d | fzf -i --scheme=path --print-query)"
    fi
    returnVal=$?

    if [ $returnVal -eq 0 ]; then
      selected=$(echo "$selected" | sed -n 2p)
    else
      handle_creation "$selected"
      echo "No match found"
      exit 1
    fi

    repo_dir=$(dirname "$selected")
    owner_dir=$(dirname "$repo_dir")
    branch_name=$(basename "$selected")
    repo_name=$(basename "$repo_dir")
    owner_name=$(basename "$owner_dir")

    selected_name="$owner_name/$repo_name/$branch_name"

    create_or_attach_to_tmux_session "$selected_name" "$selected"
  fi
    find "$dir" -mindepth 4 -maxdepth 4 -type d 
    exit 0
}

handle_delete() {
  if $withFzf; then
    if $withPreview; then
      selected="$(find "$dir" -mindepth 4 -maxdepth 4 -type d | fzf -i --scheme=path --preview="git --git-dir={}/.git --no-pager -c color.ui=always show --summary --format=fuller" --prompt="Select workspace to delete: ")"
    else
      selected="$(find "$dir" -mindepth 4 -maxdepth 4 -type d | fzf -i --scheme=path --prompt="Select workspace to delete: ")"
    fi
    returnVal=$?

    if [ $returnVal -ne 0 ]; then
      echo "No workspace selected for deletion" 1>&2;
      exit 1
    fi
  else
    echo "Error: -d flag requires fzf to be enabled" 1>&2;
    exit 1
  fi

  # Get the directory structure
  repo_dir=$(dirname "$selected")
  owner_dir=$(dirname "$repo_dir")
  branch_name=$(basename "$selected")
  repo_name=$(basename "$repo_dir")
  owner_name=$(basename "$owner_dir")

  # Confirm deletion
  echo "About to delete workspace: $owner_name/$repo_name/$branch_name" 1>&2;
  echo "Path: $selected" 1>&2;
  echo -n "Are you sure? (y/N): " 1>&2;
  read -r confirmation

  if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
    echo "Deletion cancelled" 1>&2;
    exit 0
  fi

  # Check if this is a git worktree
  if [ -f "$selected/.git" ]; then
    echo "Removing git worktree..." 1>&2;
    
    # Find the main worktree to get the git directory
    remote_head=$(get_remote_head_branch_from_remote "$owner_name/$repo_name")
    main_git_dir="$repo_dir/$remote_head/.git"
    
    if [ -d "$main_git_dir" ]; then
      git --git-dir "$main_git_dir" worktree remove "$selected" --force
      echo "Git worktree removed" 1>&2;
    else
      echo "Warning: Could not find main git directory, removing directory only" 1>&2;
      rm -rf "$selected"
    fi
  else
    echo "Removing directory..." 1>&2;
    rm -rf "$selected"
  fi

  echo "Workspace deleted: $owner_name/$repo_name/$branch_name" 1>&2;
  exit 0
}

# delete_worktree <worktree_path>
# Removes a worktree directory, using git worktree remove if it's a git worktree
# Resolves the main git directory locally (no network calls)
delete_worktree() {
  wt_path="$1"
  repo_dir=$(dirname "$wt_path")

  if [ -f "$wt_path/.git" ]; then
    # This is a linked worktree - resolve the main .git dir from the gitdir pointer
    # The .git file contains: gitdir: /path/to/main/.git/worktrees/<name>
    gitdir_line=$(cat "$wt_path/.git" | head -1)
    worktree_git_path="${gitdir_line#gitdir: }"
    # Go up two levels: .git/worktrees/<name> -> .git
    main_git_dir=$(dirname "$(dirname "$worktree_git_path")")

    if [ -d "$main_git_dir" ]; then
      git --git-dir "$main_git_dir" worktree remove "$wt_path" --force
    else
      echo "Warning: Could not resolve main git directory, removing directory only" 1>&2;
      rm -rf "$wt_path"
    fi
  else
    rm -rf "$wt_path"
  fi
}

# handle_gc [threshold_days]
# Lists worktrees that haven't been touched in at least threshold_days (default: 30)
handle_gc() {
  threshold=${1:-30}

  # Validate threshold is a number
  case "$threshold" in
    ''|*[!0-9]*) echo "Error: threshold must be a positive integer" 1>&2; exit 1 ;;
  esac

  stale_count=0

  echo "Scanning for worktrees not touched in ${threshold}+ days..." 1>&2;
  echo "" 1>&2;

  # Use temp files to avoid subshell variable issues with piped while-read
  gc_tmpfile=$(mktemp)
  find "$dir" -mindepth 4 -maxdepth 4 -type d > "$gc_tmpfile"

  # Collect stale worktrees sorted by age (oldest first)
  entries=""
  while IFS= read -r worktree; do
    if is_primary_worktree "$worktree"; then
      continue
    fi

    age=$(get_worktree_age_days "$worktree")
    if [ "$age" = "unknown" ]; then
      continue
    fi

    if [ "$age" -ge "$threshold" ]; then
      entries="${entries}${age} ${worktree}\n"
      stale_count=$((stale_count + 1))
    fi
  done < "$gc_tmpfile"
  rm -f "$gc_tmpfile"

  if [ "$stale_count" -eq 0 ]; then
    echo "No stale worktrees found (threshold: ${threshold} days)" 1>&2;
    exit 0
  fi

  echo "Found ${stale_count} stale worktree(s):" 1>&2;
  echo "" 1>&2;

  # Sort by age descending (oldest first) and display
  printf '%b' "$entries" | sort -rn | while IFS=' ' read -r age worktree; do
    [ -z "$age" ] && continue
    display_name=$(get_last_number_of_slugs "$worktree" 3)
    human_age=$(format_age "$age")
    printf "  %-40s %s ago\n" "$display_name" "$human_age" 1>&2;
  done

  echo "" 1>&2;
  echo "Run 'f clean <days>' to remove worktrees older than <days> days" 1>&2;
  exit 0
}

# handle_clean <days>
# Removes all worktrees not touched in <days> days, with confirmation
handle_clean() {
  if [ -z "$1" ]; then
    echo "Error: 'clean' requires a number of days" 1>&2;
    echo "Usage: f clean <days>" 1>&2;
    exit 1
  fi

  threshold=$1

  # Validate threshold is a number
  case "$threshold" in
    ''|*[!0-9]*) echo "Error: '<days>' must be a positive integer" 1>&2; exit 1 ;;
  esac

  echo "Scanning for worktrees not touched in ${threshold}+ days..." 1>&2;
  echo "" 1>&2;

  # Use temp file to avoid subshell variable issues with piped while-read
  clean_tmpfile=$(mktemp)
  find "$dir" -mindepth 4 -maxdepth 4 -type d > "$clean_tmpfile"

  # Collect candidates
  candidates=""
  candidate_count=0
  while IFS= read -r worktree; do
    if is_primary_worktree "$worktree"; then
      continue
    fi

    age=$(get_worktree_age_days "$worktree")
    if [ "$age" = "unknown" ]; then
      continue
    fi

    if [ "$age" -ge "$threshold" ]; then
      candidates="${candidates}${age} ${worktree}\n"
      candidate_count=$((candidate_count + 1))
    fi
  done < "$clean_tmpfile"
  rm -f "$clean_tmpfile"

  if [ "$candidate_count" -eq 0 ]; then
    echo "No worktrees found older than ${threshold} days" 1>&2;
    exit 0
  fi

  echo "The following ${candidate_count} worktree(s) will be removed:" 1>&2;
  echo "" 1>&2;

  printf '%b' "$candidates" | sort -rn | while IFS=' ' read -r age worktree; do
    [ -z "$age" ] && continue
    display_name=$(get_last_number_of_slugs "$worktree" 3)
    human_age=$(format_age "$age")
    printf "  %-40s %s ago\n" "$display_name" "$human_age" 1>&2;
  done

  echo "" 1>&2;
  printf "Are you sure you want to delete these worktrees? (y/N): " 1>&2;
  read -r confirmation

  if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
    echo "Clean cancelled" 1>&2;
    exit 0
  fi

  echo "" 1>&2;

  # Use a temp file to avoid subshell variable loss from pipeline
  tmpfile=$(mktemp)
  printf '%b' "$candidates" > "$tmpfile"
  while IFS=' ' read -r age worktree; do
    [ -z "$age" ] && continue
    display_name=$(get_last_number_of_slugs "$worktree" 3)
    echo "Removing ${display_name}..." 1>&2;
    if delete_worktree "$worktree"; then
      echo "  Removed" 1>&2;
    else
      echo "  Failed to remove" 1>&2;
    fi
  done < "$tmpfile"
  rm -f "$tmpfile"

  echo "" 1>&2;
  echo "Clean complete: removed ${candidate_count} worktree(s)" 1>&2;
  exit 0
}

# Handle subcommands before getopts
case "${1:-}" in
  gc)
    shift
    handle_gc "$@"
    ;;
  clean)
    shift
    handle_clean "$@"
    ;;
esac

while getopts ":hr:g:lpLde" o; do
    case "${o}" in
        h) usage ;;
        r) dir=${OPTARG} ;;
        g) gitDomain=${OPTARG} ;;
        l) handle_list ;;
        L) withFzf=false; handle_list ;;
        p) printPathOnly=true ;;
        e) ensureWorkspace=true; printPathOnly=true ;;
        d) handle_delete ;;
        *) usage ;;
    esac
done

shift $((OPTIND-1))

if [ ! -t 0 ]; then
  input=$(cat)
  handle_creation "$input"
  exit 1
fi

# Need to get the last argument
if [ $# -eq 0 ]; then
  usage
fi

handle_creation "${@: -1}"
