#!/bin/sh

# root dir will be $HOME/code
# default git domain will be github.com
dir=$HOME/code
gitDomain=github.com

# TODO: Overrides for these
tmuxPath=$(which tmux)
gitPath=$(which git)

withPreview=true
printPathOnly=false

currentRepoRootPath=""

usage() {
  echo "usage: $0 [-r <root directory>] [-g <git domain>] [-p] <repo>" 1>&2; 
  echo "  -h                  display this usage" 1>&2; 
  echo "  -l                  list all of the available workspaces via. fzf" 1>&2; 
  echo "  -d                  delete a particular workspace" 1>&2; 
  echo "  -p                  print path only (don't create/attach tmux session)" 1>&2; 
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
      cp -R -c "$1/node_modules" "$2"
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
      cp -P -c "$file" "$dest_base/$file"
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
  matching_directories_count=$(echo "$matching_directories" | grep -c '^' | tr -d ' ')

  if [ "$matching_directories_count" -eq 1 ]; then
    session_name=$(get_last_number_of_slugs "$matching_directories" 3)
    create_or_attach_to_tmux_session "$session_name" "$matching_directories"
  elif [ "$matching_directories_count" -eq 0 ]; then
    # need to check for the $working_directory/$repo_name existing
    # if not - attempt to clone and checkout the branch
    matching_directories=$(find_matching_repo_dirs "$repo_name")
    matching_directories_count=$(echo "$matching_directories" | grep -c '^' | tr -d ' ')

    if [ "$matching_directories_count" -eq 1 ]; then
      currentRepoRootPath=$matching_directories
      checkout_branch "$branch_name"
    elif [ "$matching_directories_count" -eq 0 ]; then
      echo "Repository pattern $repo_name/$branch_name is ambiguous - please use owner/repo/branch format" 1>&2;
      exit 1
    fi
  fi
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
    handle_repo_branch_pattern "$repo_name" "$branch_name"
  fi

  # check for <owner>/<repo>/<branch> pattern
  if [[ $1 =~ ^[^/]+/[^/]+/[^/]+$ ]]; then
    owner_name=$(echo "$1" | cut -d'/' -f1)
    repo_name=$(echo "$1" | cut -d'/' -f2)
    branch_name=$(echo "$1" | cut -d'/' -f3)
    handle_owner_repo_branch_pattern "$owner_name" "$repo_name" "$branch_name"
  fi
}

handle_list() {
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
}

while getopts ":h:r:g:lp" o; do
    case "${o}" in
        h) usage ;;
        r) dir=${OPTARG} ;;
        g) gitDomain=${OPTARG} ;;
        l) handle_list ;;
        p) printPathOnly=true ;;
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

