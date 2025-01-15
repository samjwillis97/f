#!/bin/bash

# root dir will be $HOME/code
# default git domain will be github.com
dir=$HOME/code
gitDomain=github.com

# TODO: Overrides for these
tmuxPath=$(which tmux)
gitPath=$(which git)

withPreview=true

currentRepoRootPath=""

usage() {
  echo "usage: $0 [-d <root directory>] [-g <git domain>] <repo>" 1>&2; 
  echo "  -h                  display this usage" 1>&2; 
  echo "  -l                  list all of the available workspaces via. fzf" 1>&2; 
  echo "  -d                  delete a particular workspace" 1>&2; 
  exit 1;
}

# create_or_attach_to_tmux_session <session_name> <working_directory>
create_or_attach_to_tmux_session() {
  tmux_running=$(pgrep "$tmuxPath")

  if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
      tmux new-session -s "$1" -c "$2"
      exit 0
  fi

  if ! tmux has-session -t="$1" 2> /dev/null; then
      tmux new-session -ds "$1" -c "$2"
  fi

  if [[ -z $TMUX ]]; then
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
  find "$dir" -mindepth 4 -maxdepth 4 -type d -name "$2" -path "*/$1/$2"
}

# find_matching_repo_dirs <repo>
find_matching_repo_dirs() {
  find "$dir" -mindepth 3 -maxdepth 3 -type d -name "$1" -path "*/$1"
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
  all_branches=($(git --no-pager --git-dir "$1" branch -r))
  echo "${all_branches[2]}"
}

# get_remote_head_branch_from_remote <owner/repo>
get_remote_head_branch_from_remote() {
  git remote show "git@$gitDomain:$1.git" | sed -n '/HEAD branch/s/.* //p'
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

# checkout_branch <branch_name>
checkout_branch() {
  local_branches=($(get_local_branch_directories))
  git_directory="$currentRepoRootPath/${local_branches[0]}/.git"

  echo "fetching repo..."
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
    echo "checking out new branch..."
    git worktree add -b "$1" "$branch_directory" "origin/main"
  else
    echo "checkout out existing branch..."
    git --git-dir "$git_directory" worktree add "$branch_directory" "origin/$1"
  fi

  echo "creating new tmux session..."
  session_name=$(get_last_number_of_slugs "$branch_directory" 3)
  create_or_attach_to_tmux_session "$session_name" "$branch_directory"
}

# clone_repo <repo>
clone_repo() {
  echo "going to clone repo..."
  echo "fetching remote branch head..."
  remote_head_branch=$(get_remote_head_branch_from_remote "$1")
}

# handle_repo_branch_pattern <repo> <branch>
handle_repo_branch_pattern() {
  repo_name=$1
  branch_name=$2

  matching_directories=$(find_matching_branch_dirs "$repo_name" "$branch_name")
  matching_directories_count=$(find_matching_branch_dirs "$repo_name" "$branch_name" | wc -l)

  if [ "$matching_directories_count" -eq 1 ]; then
    session_name=$(get_last_number_of_slugs "$matching_directories" 3)
    create_or_attach_to_tmux_session "$session_name" "$matching_directories"
  elif [ "$matching_directories_count" -eq 0 ]; then
    # need to check for the $working_directory/$repo_name existing
    # if not - attempt to clone and checkout the branch
    matching_directories=$(find_matching_repo_dirs "$repo_name")
    matching_directories_count=$(find_matching_repo_dirs "$repo_name" | wc -l)

    if [ "$matching_directories_count" -eq 1 ]; then
      currentRepoRootPath=$matching_directories
      checkout_branch "$branch_name"
    elif [ "$matching_directories_count" -eq 0 ]; then
      echo "Need to clone"
      currentRepoRootPath="$dir/$1/$2"
      clone_repo "$1/$2"
      exit 0
    fi

    exit 0
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
  # check for git(ea):.git url pattern
}

handle_list() {
  if $withPreview; then
    selected="$(find "$dir" -mindepth 4 -maxdepth 4 -type d | fzf -i --scheme=path --print-query --preview="git --git-dir={}/.git lg3")"
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

# TODO: Handle piping from stdin
while getopts ":h:d:g:l" o; do
    case "${o}" in
        h) usage ;;
        d) dir=${OPTARG} ;;
        g) gitDomain=${OPTARG} ;;
        l) handle_list ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ ! -t 0 ]; then
  input=$(cat)
  handle_creation "$input"
  exit 1
fi

