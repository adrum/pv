//! pv — a fast PHP version manager.

mod archive;
mod cache;
mod config;
mod doctor;
mod install;
mod installs;
mod manifest;
mod net;
mod paths;
mod platform;
mod resolve;
mod selfupdate;
mod shims;
mod version;

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};

use crate::config::Config;
use crate::resolve::{Request, Resolution};
use crate::version::{Selector, Version};

#[derive(Parser)]
#[command(
    name = "pv",
    version,
    about = "Install and switch PHP versions in seconds",
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Install a PHP version: 8.4, 8.4.3, or latest
    Install {
        /// Version or line to install
        version: String,
        /// Reinstall even when the same artifact is already installed
        #[arg(long)]
        force: bool,
    },
    /// Remove an installed PHP version
    Uninstall {
        /// Version or line to remove
        version: String,
    },
    /// List installed versions
    List(ListArgs),
    /// Write .php-version in the current directory
    Pin {
        /// Version or line to pin
        version: String,
    },
    /// Show or set the version used when nothing pins one
    Default {
        /// Version or line to make the default; omit to show the current one
        version: Option<String>,
    },
    /// Print the binary that would run here, and nothing else
    Which {
        /// Command to resolve
        #[arg(default_value = "php")]
        command: String,
    },
    /// Run a command under the resolved version
    #[command(alias = "exec")]
    Run {
        /// Command to run, as provided by the resolved PHP
        command: String,
        /// Arguments passed through untouched
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Print the version that would be used here, and where it came from
    Resolve {
        /// Print nothing unless a file or the environment pins a version
        #[arg(long)]
        pinned_only: bool,
        /// Also print what chose it
        #[arg(long)]
        source: bool,
    },
    /// Print shell setup for PATH (add `eval "$(pv init zsh)"` to your profile)
    Init {
        /// zsh, bash, sh or fish
        #[arg(default_value = "zsh")]
        shell: String,
        /// Also emit an optional hook that switches version on cd
        #[arg(long)]
        hook: bool,
    },
    /// Regenerate the shims
    Rehash,
    /// Inspect or clear the download cache
    #[command(subcommand)]
    Cache(CacheCommand),
    /// Check the installation and report anything that would fail silently
    Doctor,
    /// Manage pv itself
    #[command(subcommand)]
    #[command(name = "self")]
    Zelf(SelfCommand),
}

#[derive(Args)]
struct ListArgs {
    /// List what can be installed instead of what is installed
    #[arg(long)]
    remote: bool,
    /// With --remote, show every published patch rather than the newest few
    #[arg(long)]
    all: bool,
}

#[derive(Subcommand)]
enum CacheCommand {
    /// Show what the cache holds
    Status,
    /// Remove cached tarballs no installed version came from
    Prune,
    /// Remove every cached tarball
    Clear,
}

#[derive(Subcommand)]
enum SelfCommand {
    /// Replace this binary with the newest published build
    Update {
        /// Reinstall even when this is already the newest build
        #[arg(long)]
        force: bool,
    },
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(err) => {
            eprintln!("pv: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<ExitCode> {
    match Cli::parse().command {
        Command::Install { version, force } => cmd_install(&version, force),
        Command::Uninstall { version } => cmd_uninstall(&version),
        Command::List(args) => cmd_list(args.remote, args.all),
        Command::Pin { version } => cmd_pin(&version),
        Command::Default { version } => cmd_default(version.as_deref()),
        Command::Which { command } => cmd_which(&command),
        Command::Run { command, args } => cmd_run(&command, &args),
        Command::Resolve {
            pinned_only,
            source,
        } => cmd_resolve(pinned_only, source),
        Command::Init { shell, hook } => cmd_init(&shell, hook),
        Command::Rehash => cmd_rehash(),
        Command::Cache(command) => cmd_cache(command),
        Command::Doctor => cmd_doctor(),
        Command::Zelf(SelfCommand::Update { force }) => {
            selfupdate::update(force)?;
            Ok(ExitCode::SUCCESS)
        }
    }
}

/// Resolve using the machine's real state.
fn current_resolution() -> Result<Resolution> {
    let config = Config::load()?;
    let installed = installs::installed()?;
    let cwd = std::env::current_dir().context("could not read the current directory")?;
    let environment = std::env::var("PV_PHP_VERSION").ok();
    resolve::resolve(&Request {
        cwd: &cwd,
        installed: &installed,
        strategy: config.strategy,
        default: config.default.as_deref(),
        environment: environment.as_deref(),
    })
}

fn cmd_install(version: &str, force: bool) -> Result<ExitCode> {
    let selector: Selector = version.parse()?;
    let outcome = install::install(&selector, force)?;
    if !outcome.changed {
        println!(
            "PHP {} is already installed — `pv install {} --force` reinstalls it",
            outcome.version, outcome.version
        );
        return Ok(ExitCode::SUCCESS);
    }

    println!("installed PHP {}", outcome.version);
    print_path_advice()?;
    Ok(ExitCode::SUCCESS)
}

/// Everything a fresh install needs to hear, and nothing it does not.
fn print_path_advice() -> Result<()> {
    let status = shims::path_status("php")?;
    if !status.on_path {
        println!();
        println!("pv's shims are not on PATH yet. Add this to your shell profile:");
        println!("  eval \"$(pv init zsh)\"");
        println!("or, equivalently:");
        println!("  export PATH=\"{}:$PATH\"", status.shims.display());
        println!("then open a new shell. `pv doctor` will confirm it.");
        return Ok(());
    }
    if !status.shadowed_by.is_empty() {
        let owners: Vec<String> = status
            .shadowed_by
            .iter()
            .map(|path| path.display().to_string())
            .collect();
        println!();
        println!(
            "warning: {} comes before pv's shims on PATH and owns the name `php`.",
            owners.join(", ")
        );
        println!("Run `pv doctor` for the fix.");
        return Ok(());
    }
    // Shells cache command locations, so `php` may still resolve to a path
    // recorded before the shim existed — or to nothing at all.
    println!("If `php` still points somewhere else, run `hash -r` or open a new shell.");
    Ok(())
}

fn cmd_uninstall(version: &str) -> Result<ExitCode> {
    let selector: Selector = version.parse()?;
    let installed = installs::installed()?;
    let Some(target) = selector.best(&installed) else {
        bail!("PHP {selector} is not installed — `pv list` shows what is");
    };
    installs::remove(&target)?;
    shims::sync()?;
    println!("removed PHP {target}");

    if installs::installed()?.is_empty() {
        println!("no PHP installed now — `pv install 8.4` gets one back");
    }
    Ok(ExitCode::SUCCESS)
}

/// Patches per minor line shown by `pv list --remote` without `--all`.
const REMOTE_PATCHES_PER_LINE: usize = 3;

fn cmd_list(remote: bool, all: bool) -> Result<ExitCode> {
    let installed = installs::installed()?;

    if remote {
        let config = Config::load()?;
        let platform = platform::current()?;
        let manifest = manifest::Manifest::fetch(&config.manifest_url())?;
        let available = manifest.php_versions(&platform);
        if available.is_empty() {
            println!("no PHP builds published for {platform}");
            return Ok(ExitCode::SUCCESS);
        }

        // Trim the listing, never the catalogue: older patches stay
        // installable by exact version, and anything already installed is
        // shown regardless of age — hiding a version the user is standing on
        // would read as it having been withdrawn.
        let shown = if all {
            available.clone()
        } else {
            let mut shown = version::newest_per_line(&available, REMOTE_PATCHES_PER_LINE);
            for version in &installed {
                if available.contains(version) && !shown.contains(version) {
                    shown.push(*version);
                }
            }
            shown.sort();
            shown
        };
        let hidden = available.len() - shown.len();

        for version in shown.iter().rev() {
            let marker = if installed.contains(version) {
                " (installed)"
            } else {
                ""
            };
            println!("{version}{marker}");
        }
        if hidden > 0 {
            println!(
                "\n{hidden} older {} not shown — `pv list --remote --all` lists them, and \
                 any of them installs by exact version",
                if hidden == 1 { "patch" } else { "patches" }
            );
        }
        return Ok(ExitCode::SUCCESS);
    }

    if installed.is_empty() {
        println!("no PHP installed — run `pv install 8.4`");
        return Ok(ExitCode::SUCCESS);
    }

    // Marking the active one is the reason this command exists.
    let active = current_resolution().ok();
    for version in installed.iter().rev() {
        match &active {
            Some(resolution) if resolution.version == *version => {
                println!("* {version}  ({})", resolution.source);
            }
            _ => println!("  {version}"),
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_pin(version: &str) -> Result<ExitCode> {
    let selector: Selector = version.parse()?;
    let path = PathBuf::from(resolve::VERSION_FILE);
    // A bare version string, one line, no `php-` prefix.
    std::fs::write(&path, format!("{selector}\n"))
        .with_context(|| format!("could not write {}", path.display()))?;
    println!("pinned {selector} in {}", resolve::VERSION_FILE);

    let installed = installs::installed()?;
    if selector.best(&installed).is_none() {
        println!("PHP {selector} is not installed yet — run `pv install {selector}`");
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_default(version: Option<&str>) -> Result<ExitCode> {
    let mut config = Config::load()?;
    let Some(version) = version else {
        match &config.default {
            Some(default) => println!("{default}"),
            None => println!("no default set — pv falls back to the newest installed version"),
        }
        return Ok(ExitCode::SUCCESS);
    };

    let selector: Selector = version.parse()?;
    config.default = Some(selector.to_string());
    config.save()?;
    println!("default is now {selector}");

    let installed = installs::installed()?;
    if selector.best(&installed).is_none() {
        println!("PHP {selector} is not installed yet — run `pv install {selector}`");
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_which(command: &str) -> Result<ExitCode> {
    // Read-only, always: resolve and print, never install, never create state.
    // Shims depend on this, and so do scripts asking "what would run here?".
    let resolution = current_resolution()?;
    let path = binary_or_explain(&resolution.version, command)?;
    println!("{}", path.display());
    Ok(ExitCode::SUCCESS)
}

fn cmd_run(command: &str, args: &[String]) -> Result<ExitCode> {
    use std::os::unix::process::CommandExt;

    let resolution = current_resolution()?;
    let path = binary_or_explain(&resolution.version, command)?;

    // exec, so signals, exit codes and job control belong to PHP rather than
    // to a pv process sitting in the middle.
    let error = std::process::Command::new(&path).args(args).exec();
    Err(error).with_context(|| format!("could not run {}", path.display()))
}

fn binary_or_explain(version: &Version, command: &str) -> Result<PathBuf> {
    let path = installs::binary_path(version, command)?;
    if path.is_file() {
        return Ok(path);
    }
    let available = installs::commands(version)?;
    bail!(
        "PHP {version} does not provide `{command}` — it provides: {}",
        if available.is_empty() {
            format!("nothing — the install looks broken, try `pv install {version} --force`")
        } else {
            available.join(", ")
        }
    )
}

/// Print the resolved version for scripts and for the shell hook.
///
/// Read-only, like `which`. `--pinned-only` prints nothing when the version
/// comes from a fallback rather than a pin: the hook exports what this prints,
/// and exporting a fallback would freeze it, outranking the `.php-version` of
/// every directory the shell later moves into.
fn cmd_resolve(pinned_only: bool, source: bool) -> Result<ExitCode> {
    let resolution = match current_resolution() {
        Ok(resolution) => resolution,
        // Nothing resolves here. For the hook that means "clear the override",
        // which is a silent success rather than an error the shell must cope
        // with on every prompt.
        Err(_) if pinned_only => return Ok(ExitCode::SUCCESS),
        Err(err) => return Err(err),
    };

    let pinned = matches!(
        resolution.source,
        resolve::Source::Environment
            | resolve::Source::VersionFile(_)
            | resolve::Source::Composer(_, _)
    );
    if pinned_only && !pinned {
        return Ok(ExitCode::SUCCESS);
    }

    if source {
        println!("{} ({})", resolution.version, resolution.source);
    } else {
        println!("{}", resolution.version);
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_init(shell: &str, hook: bool) -> Result<ExitCode> {
    match shell {
        "zsh" | "bash" | "sh" | "fish" => {}
        other => bail!("pv has no init snippet for `{other}` — try zsh, bash, sh or fish"),
    }
    print!("{}", shims::init_snippet(shell, &paths::shims_dir()?));
    if hook {
        let pv = std::env::current_exe().context("could not determine pv's own path")?;
        print!("{}", shims::hook_snippet(shell, &pv));
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_cache(command: CacheCommand) -> Result<ExitCode> {
    let entries = cache::entries()?;
    match command {
        CacheCommand::Status => {
            if entries.is_empty() {
                println!("cache is empty ({})", paths::cache_dir()?.display());
                return Ok(ExitCode::SUCCESS);
            }
            for entry in &entries {
                let name = entry.path.file_name().unwrap_or_default().to_string_lossy();
                let use_marker = if entry.in_use { "  (in use)" } else { "" };
                println!("{:>10}  {name}{use_marker}", net::megabytes(entry.bytes));
            }
            println!(
                "\n{} in {} — `pv cache prune` removes the {} nothing is installed from",
                net::megabytes(cache::total_bytes(&entries)),
                paths::cache_dir()?.display(),
                entries.iter().filter(|entry| !entry.in_use).count(),
            );
        }
        CacheCommand::Prune => {
            let (removed, freed) = cache::remove(true)?;
            println!(
                "removed {removed} cached tarballs, freed {}",
                net::megabytes(freed)
            );
        }
        CacheCommand::Clear => {
            // Safe by construction: a cached tarball is only ever a download
            // shortcut, and every installed tree stays where it is.
            let (removed, freed) = cache::remove(false)?;
            println!(
                "removed {removed} cached tarballs, freed {}",
                net::megabytes(freed)
            );
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_rehash() -> Result<ExitCode> {
    let written = shims::sync()?;
    if written.is_empty() {
        println!("no shims written — no PHP installed yet");
    } else {
        println!("shims: {}", written.join(", "));
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_doctor() -> Result<ExitCode> {
    let findings = doctor::run()?;
    let (report, healthy) = doctor::report(&findings);
    print!("{report}");
    Ok(if healthy {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}
