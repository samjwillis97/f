use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{exit, Command},
};

use clap::Parser;
use reflink_copy::reflink_or_copy;
use regex::Regex;

use reqwest::{
    blocking::{Client, ClientBuilder},
    header::{HeaderMap, HeaderValue},
};
use serde::Deserialize;
use walkdir::{DirEntry, WalkDir};

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    input: String,

    #[arg(short, long)]
    branch: Option<String>,
}

struct Config {
    root_dir: PathBuf,
    default_domain: String,
}

impl Config {
    fn new() -> Self {
        Default::default()
    }

    fn get_default_top_level_dir(&self) -> PathBuf {
        self.root_dir.join(&self.default_domain)
    }
}

impl Default for Config {
    fn default() -> Self {
        let root_dir =
            PathBuf::from(env::var("HOME").expect("Unable to get home directory")).join("code");

        Config {
            root_dir,
            default_domain: "github.com".to_string(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct GithubGetRepoResponse {
    default_branch: String,
}

#[derive(Debug)]
struct RepoInfo {
    url: String,
    domain: String,
    owner: String,
    name: String,
}

impl RepoInfo {
    fn from_git_url(input: &str) -> Self {
        let url_captures = git_url_regex()
            .captures(input)
            .expect("Invalid git URL input");

        let owner_name_captures = double_value_regex()
            .captures(url_captures.get(2).unwrap().as_str())
            .expect("Invalid owner and name");

        RepoInfo {
            url: input.to_string(),
            domain: url_captures.get(1).unwrap().as_str().to_string(),
            owner: owner_name_captures.get(1).unwrap().as_str().to_string(),
            name: owner_name_captures.get(2).unwrap().as_str().to_string(),
        }
    }

    fn from_owner_name(cfg: &Config, input: &str) -> Self {
        let captures = double_value_regex()
            .captures(input)
            .expect("Invalid double value input");

        RepoInfo {
            domain: cfg.default_domain.clone(),
            url: format!(
                "git@{}:{}/{}.git",
                cfg.default_domain.clone(),
                captures.get(1).unwrap().as_str().to_string(),
                captures.get(2).unwrap().as_str().to_string(),
            ),
            owner: captures.get(1).unwrap().as_str().to_string(),
            name: captures.get(2).unwrap().as_str().to_string(),
        }
    }

    fn from_owner_name_branch(cfg: &Config, input: &str) -> Self {
        let captures = triple_value_regex()
            .captures(input)
            .expect("Invalid triple value input");

        RepoInfo {
            domain: cfg.default_domain.clone(),
            url: format!(
                "git@{}:{}/{}.git",
                cfg.default_domain.clone(),
                captures.get(1).unwrap().as_str().to_string(),
                captures.get(2).unwrap().as_str().to_string(),
            ),
            owner: captures.get(1).unwrap().as_str().to_string(),
            name: captures.get(2).unwrap().as_str().to_string(),
        }
    }

    fn get_owner_name(&self) -> String {
        return format!("{}/{}", self.owner, self.name);
    }

    fn get_repo_path(&self, cfg: &Config) -> PathBuf {
        cfg.root_dir
            .join(self.domain.as_str())
            .join(self.owner.as_str())
            .join(self.name.as_str())
    }
}

fn url_regex() -> Regex {
    Regex::new(r"://").unwrap()
}

fn git_url_regex() -> Regex {
    Regex::new(r"\Agit(?:ea)?@([^:]+):(.*)(.git)").unwrap()
}

fn double_value_regex() -> Regex {
    Regex::new(r"\A([\w\.\-]+)/([\w\.\-]+)\z").unwrap()
}

fn triple_value_regex() -> Regex {
    Regex::new(r"\A([\w\.\-]+)/([\w\.\-]+)/([\w\.\-]+)\z").unwrap()
}

// These find functions could be cleaned up, and be less error prone, maybe walkdirs inside them
fn find_matching_owner_dirs(owner: &str, dirs: &Vec<DirEntry>) -> Vec<DirEntry> {
    dirs.clone()
        .into_iter()
        .filter(|d| {
            d.depth() == 2 && d.clone().into_path().parent().unwrap().file_name().unwrap() == owner
        })
        .collect::<Vec<_>>()
}

fn find_matching_repo_dirs(repo: &str, dirs: &Vec<DirEntry>) -> Vec<DirEntry> {
    dirs.clone()
        .into_iter()
        .filter(|d| d.depth() == 2 && d.clone().into_path().file_name().unwrap() == repo)
        .collect::<Vec<_>>()
}

fn find_matching_branch_dirs(branch: &str, dirs: &Vec<DirEntry>) -> Vec<DirEntry> {
    dirs.clone()
        .into_iter()
        .filter(|d| d.depth() == 3 && d.clone().into_path().file_name().unwrap() == branch)
        .collect::<Vec<_>>()
}

fn get_workspace_with_branch(cfg: &Config, search: &str) {
    let captures = triple_value_regex().captures(search).unwrap();

    let first_capture = captures.get(1).unwrap().as_str();
    let second_capture = captures.get(2).unwrap().as_str();
    let third_capture = captures.get(3).unwrap().as_str();
    let top_level_directory = cfg.get_default_top_level_dir();

    let directories = WalkDir::new(&top_level_directory)
        .max_depth(3)
        .min_depth(2)
        .into_iter()
        .map(|v| v.unwrap())
        .filter(|v| v.file_type().is_dir())
        .collect::<Vec<_>>();

    let owner_level_matches = find_matching_owner_dirs(first_capture, &directories);
    if owner_level_matches.len() == 0 {
        let repo_info = &RepoInfo::from_owner_name_branch(cfg, search);
        clone_repo(cfg, repo_info);
        checkout_branch(cfg, repo_info, third_capture);
        return;
    }

    let repo_level_matches = find_matching_repo_dirs(second_capture, &directories);
    if repo_level_matches.len() == 0 {
        let repo_info = &RepoInfo::from_owner_name_branch(cfg, search);
        clone_repo(cfg, repo_info);
        checkout_branch(cfg, repo_info, third_capture);
        return;
    }

    let branch_level_matches = find_matching_branch_dirs(third_capture, &directories);
    if branch_level_matches.len() == 0 {
        let repo_info = &RepoInfo::from_owner_name_branch(cfg, search);
        checkout_branch(cfg, repo_info, third_capture);
        return;
    }

    let binding = branch_level_matches.into_iter().next().unwrap();
    let directory = binding.path().to_str().unwrap();

    println!("{}", directory)
}

fn get_workspace_or_branch(cfg: &Config, search: &str) {
    let captures = double_value_regex().captures(search).unwrap();

    let first_capture = captures.get(1).unwrap().as_str();
    let second_capture = captures.get(2).unwrap().as_str();
    let top_level_directory = cfg.get_default_top_level_dir();

    let directories = WalkDir::new(&top_level_directory)
        .max_depth(3)
        .min_depth(2)
        .into_iter()
        .map(|v| v.unwrap())
        .filter(|v| v.file_type().is_dir())
        .collect::<Vec<_>>();

    // Check the parent of the directory and if it matches the first capture
    let owner_level_matches = find_matching_owner_dirs(first_capture, &directories);
    if owner_level_matches.len() == 0 {
        // Need to check if the first capture matches the next depth level
        let repo_level_matches = find_matching_repo_dirs(first_capture, &directories);
        if repo_level_matches.len() == 0 {
            if !check_github_user_exists(first_capture) {
                eprintln!("Unable to checkout repo - cannot find user");
                exit(1);
            }

            clone_repo(cfg, &RepoInfo::from_owner_name(cfg, search));
        }

        let branch_level_matches = find_matching_branch_dirs(second_capture, &directories);
        if branch_level_matches.len() == 0 {
            let repo_path_vec = repo_level_matches
                .first()
                .unwrap()
                .path()
                .to_str()
                .unwrap()
                .split("/")
                .collect::<Vec<_>>();
            let owner_name = &repo_path_vec[repo_path_vec.len() - 2..].join("/");
            checkout_branch(
                cfg,
                &RepoInfo::from_owner_name(cfg, &owner_name),
                second_capture,
            );
            exit(0);
        }

        println!(
            "{}",
            branch_level_matches
                .get(0)
                .unwrap()
                .path()
                .to_str()
                .unwrap()
        );
        return;
    }

    // Check the directory and if it matches the first capture
    let repo_level_matches = find_matching_repo_dirs(second_capture, &directories);
    if repo_level_matches.len() == 0 {
        eprintln!("Owner exists, repo does not.");
        let path = clone_repo(cfg, &RepoInfo::from_owner_name(cfg, search));
        println!("{}", path);
        return;
    }

    let binding = repo_level_matches.into_iter().next().unwrap();
    let directory = binding.path().to_str().unwrap();

    println!("{}", directory);
}

fn clone_repo(cfg: &Config, info: &RepoInfo) -> String {
    let repo_directory = info.get_repo_path(cfg);

    let repo_directory_path = repo_directory.as_path();

    if repo_directory_path.exists() {
        eprintln!("Repo already exists");
        exit(1);
    }

    check_git_installed();

    eprintln!("Creating: {}", repo_directory_path.to_str().unwrap());
    fs::create_dir_all(repo_directory_path).expect("Unable to create directory");

    let master_branch = get_default_branch_with_git(info).unwrap();

    let branch_directory = repo_directory.join(master_branch);
    let branch_path = branch_directory.as_path().to_str().unwrap();

    eprintln!("Cloning into: {}", branch_path);

    git_clone_command(&info.url, branch_path);

    if branch_directory.join(".envrc").exists() {
        eprintln!("Enabling direnv");
        enable_direnv(branch_path);
    }

    branch_path.to_string()
}

fn checkout_branch(cfg: &Config, info: &RepoInfo, branch: &str) {
    let repo_path = info.get_repo_path(cfg);
    if !Path::new(repo_path.as_path()).exists() {
        clone_repo(cfg, info);
    };

    let branch_path = repo_path.join(branch);
    if Path::new(branch_path.as_path()).exists() {
        eprint!("alredy exists");
        println!("{}", branch_path.as_path().to_str().unwrap());
        return;
    };

    check_git_installed();

    let main_branch = get_default_branch_with_git(info).unwrap();
    let main_branch_path = repo_path.join(main_branch);

    if !Path::new(main_branch_path.as_path()).exists() {
        panic!("Missing main branch, clone again??: {:?}", main_branch_path);
    }

    git_pull_command(&main_branch_path.as_path());
    let remote_branches = git_get_remote_branches_command(&main_branch_path.as_path());

    if let Some(_) = remote_branches
        .unwrap()
        .into_iter()
        .find(|v| v.as_str() == branch)
    {
        git_checkout_worktree(main_branch_path.as_path(), branch, false);
    } else {
        git_checkout_worktree(main_branch_path.as_path(), branch, true);
    }

    let branch_path = repo_path.join(branch);

    let main_node_modules = main_branch_path.join("node_modules");
    if main_node_modules.exists() {
        match reflink_or_copy(main_node_modules, branch_path.join("node_modules")) {
            Ok(_) => (),
            Err(e) => println!("Unable to copy node_modules: {}", e),
        }
    }

    if branch_path.join(".envrc").exists() {
        enable_direnv(branch_path.as_path().to_str().unwrap());
    }

    // todo!("Find untracked files and copy to new worktree");

    println!("{}", branch_path.to_str().unwrap());
}

fn check_git_installed() {
    Command::new("git")
        .arg("-v")
        .output()
        .expect("Unable to execute command: \"git\" ");
}

fn enable_direnv(path: &str) {
    match Command::new("direnv")
        .current_dir(path)
        .arg("allow")
        .output()
    {
        Ok(_) => (),
        Err(e) => println!("Unable to allow direnv: {}", e),
    };
}

fn git_clone_command(url: &str, out_path: &str) {
    eprintln!("Cloning repository...");
    let arg = "git clone ".to_owned() + url + " " + out_path;
    match Command::new("bash").arg("-c").arg(arg).output() {
        Ok(_) => (),
        Err(e) => panic!("Unable to clone repository: {:?}", e),
    }
}

fn git_pull_command(repo_path: &Path) {
    eprintln!("Pulling repository...");
    let arg = "git pull";
    match Command::new("bash")
        .current_dir(repo_path)
        .arg("-c")
        .arg(arg)
        .output()
    {
        Ok(_) => (),
        Err(e) => panic!("Unable to pull: {:?}", e),
    }
}

fn git_get_remote_branches_command(repo_path: &Path) -> Result<Vec<String>, &str> {
    let arg = "git branch -r";
    match Command::new("bash")
        .current_dir(repo_path)
        .arg("-c")
        .arg(arg)
        .output()
    {
        Ok(v) => Ok(String::from_utf8(v.stdout)
            .unwrap()
            .lines()
            .map(|v| v.trim())
            .filter(|v| !v.starts_with("origin/HEAD -> "))
            .map(|v| v.split_at("origin/".len()).1)
            .map(|v| v.to_string())
            .collect::<Vec<_>>()),
        Err(e) => panic!("Unable to pull: {:?}", e),
    }
}

fn git_checkout_worktree(main_branch_path: &Path, branch: &str, new_branch: bool) {
    let arg = if new_branch {
        println!("Checking out new branch: {}", branch);
        format!("git worktree add -b \"{}\" \"../{}\"", branch, branch)
    } else {
        println!("Checking out remote branch: {}", branch);
        format!("git worktree add \"../{}\" \"{}\"", branch, branch)
    };
    match Command::new("bash")
        .current_dir(main_branch_path)
        .arg("-c")
        .arg(arg)
        .output()
    {
        Ok(_) => (),
        Err(e) => println!("Unable to checkout branch: {}", e),
    }
}

fn get_default_branch_with_git(info: &RepoInfo) -> Result<String, &str> {
    let arg = format!(
        "git remote show {} | sed -n '/HEAD branch/s/.* //p'",
        info.url,
    );
    match Command::new("bash").arg("-c").arg(arg).output() {
        Ok(v) => {
            let from_utf8 = String::from_utf8(v.stdout);
            Ok(from_utf8.unwrap().trim().to_string())
        }
        Err(e) => panic!("Unable to get default branch of repository: {:?}", e),
    }
}

// TODO: How does this handle private repo's? or orgs?..
// might need to handle an auth token
fn get_default_branch_from_github(repo: &str) -> Result<String, &str> {
    let client = get_request_client();
    let url = format!("https://api.github.com/repos/{repo}");
    let response = client.get(url).send().expect("Unable to make request");
    let api_response = response.json::<GithubGetRepoResponse>();

    match api_response {
        Ok(v) => Ok(v.default_branch),
        Err(_) => Err("Unable to get default_branch"),
    }
}

fn check_github_user_exists(user: &str) -> bool {
    let client = get_request_client();
    let url = format!("https://api.github.com/users/{user}");
    let response = client.get(url).send().expect("Unable to make request");
    response.status().is_success()
}

fn get_request_client() -> Client {
    let mut headers = HeaderMap::new();
    headers.insert("Accept", HeaderValue::from_static("*/*"));
    headers.insert("User-Agent", HeaderValue::from_static("f"));
    let builder = ClientBuilder::new().default_headers(headers);
    builder.build().expect("Unable to build HTTP client")
}

fn main() {
    let cfg = Config::new();

    let args = Args::parse();

    // TODO: Clean up the 'unwrap' everywhere
    // TODO: move the print's here, so all functions will just return a str
    match &args.input {
        s if double_value_regex().is_match(&s) => get_workspace_or_branch(&cfg, s),
        s if triple_value_regex().is_match(&s) => get_workspace_with_branch(&cfg, s),
        s if git_url_regex().is_match(&s) => {
            let path = clone_repo(&cfg, &RepoInfo::from_git_url(s));
            println!("{}", path)
        }
        s if url_regex().is_match(&s) => todo!("URL value"),
        _ => todo!("Search"),
    }
}
