//! pv — a fast PHP version manager.

mod archive;
mod cache;
mod config;
mod doctor;
mod exit;
mod install;
mod installs;
mod lock;
mod lookup;
mod manifest;
mod net;
mod paths;
mod platform;
mod resolve;
mod selfupdate;
mod shims;
mod tools;
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
    /// Output format for the commands a script would call
    #[arg(long, value_enum, default_value_t = Format::Text, global = true)]
    format: Format,
    #[command(subcommand)]
    command: Command,
}

/// How a command reports its result.
///
/// The rule that makes `json` worth anything: **data on stdout, diagnostics on
/// stderr, always**. If a progress line or a warning can land in stdout, the
/// JSON is unparseable and a caller cannot tell a corrupt install from a
/// chatty one. So `json` also suppresses the human-facing chatter entirely —
/// it is a machine's view, not a decorated one.
#[derive(Copy, Clone, PartialEq, Eq, clap::ValueEnum)]
enum Format {
    Text,
    Json,
}

impl Format {
    fn is_json(self) -> bool {
        self == Format::Json
    }

    /// Print a value as JSON, or run the human-facing branch.
    fn emit(self, value: serde_json::Value, text: impl FnOnce()) -> Result<()> {
        if self.is_json() {
            println!("{}", serde_json::to_string_pretty(&value)?);
        } else {
            text();
        }
        Ok(())
    }
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
        /// zsh, bash, sh, fish or powershell
        #[arg(default_value = DEFAULT_SHELL)]
        shell: String,
        /// Also emit an optional hook that switches version on cd
        #[arg(long)]
        hook: bool,
    },
    /// Regenerate the shims
    Rehash,
    /// Install Composer or PIE, and run them under the resolved PHP
    #[command(subcommand)]
    Tool(ToolCommand),
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

/// The shell `pv init` assumes when it is not told.
const DEFAULT_SHELL: &str = if cfg!(windows) { "powershell" } else { "zsh" };

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
enum ToolCommand {
    /// Download a tool's official phar and verify it
    Install {
        /// composer or pie
        tool: tools::Tool,
    },
    /// Remove an installed tool
    Uninstall {
        /// composer or pie
        tool: tools::Tool,
    },
    /// Show which tools are installed
    List,
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
            // Diagnostics on stderr, always: stdout belongs to the data a
            // caller is parsing, even when the command fails.
            eprintln!("pv: {err:#}");
            ExitCode::from(exit::code_for(&err))
        }
    }
}

fn run() -> Result<ExitCode> {
    let cli = Cli::parse();
    let format = cli.format;
    match cli.command {
        Command::Install { version, force } => cmd_install(&version, force),
        Command::Uninstall { version } => cmd_uninstall(&version),
        Command::List(args) => cmd_list(args.remote, args.all, format),
        Command::Pin { version } => cmd_pin(&version),
        Command::Default { version } => cmd_default(version.as_deref()),
        Command::Which { command } => cmd_which(&command, format),
        Command::Run { command, args } => cmd_run(&command, &args),
        Command::Resolve {
            pinned_only,
            source,
        } => cmd_resolve(pinned_only, source, format),
        Command::Init { shell, hook } => cmd_init(&shell, hook),
        Command::Rehash => cmd_rehash(),
        Command::Tool(command) => cmd_tool(command, format),
        Command::Cache(command) => cmd_cache(command),
        Command::Doctor => cmd_doctor(format),
        Command::Zelf(SelfCommand::Update { force }) => {
            selfupdate::update(force)?;
            Ok(ExitCode::SUCCESS)
        }
    }
}

/// The `php` binary this directory resolves to.
pub fn current_php() -> Result<PathBuf> {
    let resolution = current_resolution()?;
    installs::binary_path(&resolution.version, "php")
}

/// A stable identifier for which resolution step answered.
///
/// Deliberately not the Display text, which is written for people and may be
/// reworded; these strings are interface and must not drift.
fn source_kind(source: &resolve::Source) -> &'static str {
    match source {
        resolve::Source::Environment => "environment",
        resolve::Source::VersionFile(_) => "version-file",
        resolve::Source::Composer(_, _) => "composer",
        resolve::Source::Default => "default",
        resolve::Source::NewestInstalled => "newest-installed",
    }
}

fn source_path(source: &resolve::Source) -> Option<String> {
    match source {
        resolve::Source::VersionFile(path) | resolve::Source::Composer(path, _) => {
            Some(path.display().to_string())
        }
        _ => None,
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
    warn_if_end_of_life(&outcome.version);
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

/// php.net stops releasing a line at end of life. pv's builds of it then carry
/// the security backports from Ondřej Surý's Debian packaging, which php.net
/// does not review; on Windows they are compiled against the libraries php.net
/// last shipped for the line, which get no fixes either. Without saying so, a
/// successful install reads as a supported one.
fn warn_if_end_of_life(version: &Version) {
    let Some(date) = version.end_of_life(std::time::SystemTime::now()) else {
        return;
    };
    let (major, minor) = version.line();
    eprintln!(
        "warning: PHP {major}.{minor} reached end of life on {date}, and php.net no longer releases it."
    );
    eprintln!("pv's build adds the security fixes Ondřej Surý backports for Debian");
    eprintln!("(deb.sury.org) where they exist, but php.net does not review them.");
    if cfg!(windows) {
        eprintln!("The libraries it bundles, OpenSSL among them, are php.net's last for it.");
    }
    eprintln!("Move to a supported line when you can: `pv install latest`.");
}

/// Everything a fresh install needs to hear, and nothing it does not.
fn print_path_advice() -> Result<()> {
    let status = shims::path_status("php")?;
    if !status.on_path {
        println!();
        if cfg!(windows) {
            println!("pv's shims are not on PATH yet. Add this to your PowerShell profile:");
            println!("  pv init powershell | Out-String | Invoke-Expression");
            println!("or add this directory to the front of your user PATH:");
            println!("  {}", status.shims.display());
            println!("then open a new terminal. `pv doctor` will confirm it.");
            return Ok(());
        }
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
    if cfg!(windows) {
        println!("If `php` still points somewhere else, open a new terminal.");
    } else {
        println!("If `php` still points somewhere else, run `hash -r` or open a new shell.");
    }
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

fn cmd_list(remote: bool, all: bool, format: Format) -> Result<ExitCode> {
    let installed = installs::installed()?;

    if remote {
        let config = Config::load()?;
        let platform = platform::current()?;
        let manifest = manifest::Manifest::fetch(&config.manifest_url())?;
        let available = manifest.php_versions(&platform);
        if available.is_empty() {
            format.emit(
                serde_json::json!({ "platform": platform, "available": [] }),
                || println!("no PHP builds published for {platform}"),
            )?;
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

        // JSON always carries the whole catalogue: the trimming exists to keep
        // a terminal listing readable, and silently handing a caller a subset
        // would make it miss versions it can perfectly well install.
        format.emit(
            serde_json::json!({
                "platform": platform,
                "available": available.iter().rev().map(|version| serde_json::json!({
                    "version": version.to_string(),
                    "installed": installed.contains(version),
                })).collect::<Vec<_>>(),
            }),
            || {
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
                        "\n{hidden} older {} not shown — `pv list --remote --all` lists \
                         them, and any of them installs by exact version",
                        if hidden == 1 { "patch" } else { "patches" }
                    );
                }
            },
        )?;
        return Ok(ExitCode::SUCCESS);
    }

    if installed.is_empty() {
        format.emit(serde_json::json!({ "installed": [] }), || {
            println!("no PHP installed — run `pv install 8.4`")
        })?;
        return Ok(ExitCode::SUCCESS);
    }

    // Marking the active one is the reason this command exists.
    let active = current_resolution().ok();
    let is_active = |version: &Version| {
        active
            .as_ref()
            .is_some_and(|resolution| resolution.version == *version)
    };
    format.emit(
        serde_json::json!({
            "installed": installed.iter().rev().map(|version| serde_json::json!({
                "version": version.to_string(),
                "active": is_active(version),
                "path": installs::bin_dir(version).ok().map(|p| p.display().to_string()),
            })).collect::<Vec<_>>(),
            "active": active.as_ref().map(|resolution| serde_json::json!({
                "version": resolution.version.to_string(),
                "source": source_kind(&resolution.source),
                "source_path": source_path(&resolution.source),
            })),
        }),
        || {
            for version in installed.iter().rev() {
                if is_active(version) {
                    let source = active.as_ref().expect("active is some").source.to_string();
                    println!("* {version}  ({source})");
                } else {
                    println!("  {version}");
                }
            }
        },
    )?;
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

fn cmd_which(command: &str, format: Format) -> Result<ExitCode> {
    // Read-only, always: resolve and print, never install, never create state.
    // Shims depend on this, and so do scripts asking "what would run here?".
    let resolution = current_resolution()?;
    let located = locate(&resolution.version, command)?;
    format.emit(
        serde_json::json!({
            "command": command,
            "path": located.path.display().to_string(),
            "version": resolution.version.to_string(),
            "from": if located.phar {
                "tool"
            } else if located.from_path {
                "path"
            } else {
                "version"
            },
        }),
        || println!("{}", located.path.display()),
    )?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_run(command: &str, args: &[String]) -> Result<ExitCode> {
    let resolution = current_resolution()?;
    let located = locate(&resolution.version, command)?;

    let mut process = if located.phar {
        let mut process =
            std::process::Command::new(installs::binary_path(&resolution.version, "php")?);
        process.arg(&located.path);
        process
    } else {
        std::process::Command::new(&located.path)
    };
    process.args(args);

    if located.phar {
        // Composer shells out to `php` for sub-processes and plugin scripts;
        // without this they would resolve through the shim again and could
        // disagree with the PHP running the phar itself.
        process.env(
            "PATH",
            std::env::join_paths(
                std::iter::once(installs::bin_dir(&resolution.version)?).chain(lookup::entries()),
            )?,
        );
        process.env("PV_PHP_VERSION", resolution.version.to_string());
    }

    if located.from_path {
        // A PHP tool found on PATH — Composer being the one that matters. Two
        // things make it run under the right PHP. The resolved bin directory
        // goes first, ahead of pv's own shims, so a `#!/usr/bin/env php`
        // shebang lands directly on the real binary. And the version is
        // pinned in the environment, so anything the tool spawns resolves the
        // same way rather than re-deriving it from a directory it may have
        // changed into.
        //
        // Neither helps a wrapper with an absolute PHP path baked into it —
        // nothing can, short of rewriting the wrapper — which is what the
        // doctor check exists to report.
        let mut entries = vec![installs::bin_dir(&resolution.version)?];
        entries.extend(lookup::entries());
        process.env("PATH", std::env::join_paths(entries)?);
        process.env("PV_PHP_VERSION", resolution.version.to_string());
    }

    // PHP compiles in a fixed php.ini search path that a relocatable tree
    // cannot satisfy — ours looks in /usr/local/etc/php, which is nobody's
    // install. Pointing PHPRC at the tree's own ini is what makes the shipped
    // defaults real; without it the artifact carries a config file that is
    // never read. PHP_INI_SCAN_DIR gives extensions you build yourself a
    // place to be enabled from.
    let ini = installs::ini_path(&resolution.version)?;
    if ini.is_file() {
        process.env("PHPRC", &ini);
    }
    let conf_dir = installs::conf_dir(&resolution.version)?;
    if conf_dir.is_dir() {
        process.env("PHP_INI_SCAN_DIR", &conf_dir);
    }

    hand_over(process).with_context(|| format!("could not run {}", located.path.display()))
}

/// Become the command: exec, so signals, exit codes and job control belong to
/// it rather than to a pv process sitting in the middle.
#[cfg(unix)]
fn hand_over(mut process: std::process::Command) -> std::io::Result<ExitCode> {
    use std::os::unix::process::CommandExt;
    Err(process.exec())
}

/// Windows has no exec, so pv stays in the middle and does as little there as
/// it can: wait for the command, then leave with its exit code.
#[cfg(windows)]
fn hand_over(mut process: std::process::Command) -> std::io::Result<ExitCode> {
    const CTRL_BREAK_EVENT: u32 = 1;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(
            handler: Option<unsafe extern "system" fn(u32) -> i32>,
            add: i32,
        ) -> i32;
    }

    // Ctrl+C and Ctrl+Break reach every process attached to the console, the
    // command included. What they mean is the command's decision — an
    // interactive `php -a` survives one — so pv claims to have handled them
    // and keeps waiting. A handler function rather than the "ignore Ctrl+C"
    // flag, because that flag is inherited and the command would ignore it too.
    unsafe extern "system" fn leave_it_to_the_command(event: u32) -> i32 {
        (event <= CTRL_BREAK_EVENT) as i32
    }
    // SAFETY: the handler is a plain function that touches no state.
    unsafe { SetConsoleCtrlHandler(Some(leave_it_to_the_command), 1) };

    let status = process.status()?;
    // Not ExitCode, which is a u8: Windows exit codes are 32 bits wide, and a
    // crash is reported as one that does not fit.
    std::process::exit(status.code().unwrap_or(1))
}

struct Located {
    path: PathBuf,
    /// True when the command came from PATH rather than the PHP tree.
    from_path: bool,
    /// Set when `path` is a phar, which needs php to run it.
    phar: bool,
}

/// Where `command` lives: inside the resolved PHP first, then PATH.
///
/// The PATH fallback is what makes `pv run composer install` work without pv
/// shipping Composer. pv has no business owning Composer's release cycle —
/// but it does own which PHP a PHP tool runs under, and that is the part
/// people actually get wrong.
fn locate(version: &Version, command: &str) -> Result<Located> {
    let path = installs::binary_path(version, command)?;
    if path.is_file() {
        return Ok(Located {
            path,
            from_path: false,
            phar: false,
        });
    }

    // A tool pv installed: one phar shared by every PHP, run under whichever
    // version this directory resolves to.
    if let Some(tool) = tools::Tool::from_name(command)
        && tools::is_installed(tool)?
    {
        return Ok(Located {
            path: tool.path()?,
            from_path: false,
            phar: true,
        });
    }

    if let Some(path) = lookup::on_path_excluding_shims(command)? {
        return Ok(Located {
            path,
            from_path: true,
            phar: false,
        });
    }

    let available = installs::commands(version)?;
    bail!(
        "`{command}` is not provided by PHP {version} and is not on PATH.\n\
         PHP {version} provides: {}",
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
fn cmd_resolve(pinned_only: bool, source: bool, format: Format) -> Result<ExitCode> {
    let resolution = match current_resolution() {
        Ok(resolution) => resolution,
        // Nothing resolves here. For the hook that means "clear the override",
        // which is a silent success rather than an error the shell must cope
        // with on every prompt.
        Err(_) if pinned_only => {
            if format.is_json() {
                println!("null");
            }
            return Ok(ExitCode::SUCCESS);
        }
        Err(err) => return Err(err),
    };

    let pinned = matches!(
        resolution.source,
        resolve::Source::Environment
            | resolve::Source::VersionFile(_)
            | resolve::Source::Composer(_, _)
    );
    if pinned_only && !pinned {
        if format.is_json() {
            println!("null");
        }
        return Ok(ExitCode::SUCCESS);
    }

    // `source` is the field that answers "why am I getting this version?"
    // without a second command, which is the question a caller actually has.
    format.emit(
        serde_json::json!({
            "version": resolution.version.to_string(),
            "binary": locate(&resolution.version, "php").ok().map(|l| l.path.display().to_string()),
            "source": source_kind(&resolution.source),
            "source_path": source_path(&resolution.source),
            "pinned": pinned,
        }),
        || {
            if source {
                println!("{} ({})", resolution.version, resolution.source);
            } else {
                println!("{}", resolution.version);
            }
        },
    )?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_init(shell: &str, hook: bool) -> Result<ExitCode> {
    match shell {
        "zsh" | "bash" | "sh" | "fish" | "powershell" | "pwsh" => {}
        other => {
            bail!("pv has no init snippet for `{other}` — try zsh, bash, sh, fish or powershell")
        }
    }
    print!("{}", shims::init_snippet(shell, &paths::shims_dir()?));
    if hook {
        let pv = std::env::current_exe().context("could not determine pv's own path")?;
        print!("{}", shims::hook_snippet(shell, &pv));
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_tool(command: ToolCommand, format: Format) -> Result<ExitCode> {
    match command {
        ToolCommand::Install { tool } => {
            let outcome = tools::install(tool)?;
            format.emit(
                serde_json::json!({
                    "tool": outcome.tool.name(),
                    "version": outcome.version,
                    "path": outcome.path.display().to_string(),
                }),
                || {
                    println!("installed {} {}", outcome.tool.name(), outcome.version);
                    println!(
                        "it runs under whichever PHP resolves here — try `{} --version`",
                        outcome.tool.name()
                    );
                },
            )?;
            // The tool is only reachable by name once it has a shim.
            shims::sync()?;
        }
        ToolCommand::Uninstall { tool } => {
            if !tools::is_installed(tool)? {
                bail!("{} is not installed", tool.name());
            }
            tools::uninstall(tool)?;
            shims::sync()?;
            println!("removed {}", tool.name());
        }
        ToolCommand::List => {
            let mut rows = Vec::new();
            for tool in tools::Tool::all() {
                let record = tools::read_record(tool)?;
                rows.push(serde_json::json!({
                    "tool": tool.name(),
                    "installed": tools::is_installed(tool)?,
                    "version": record.as_ref().map(|r| r.version.clone()),
                    "path": tools::is_installed(tool)?
                        .then(|| tool.path().ok().map(|p| p.display().to_string()))
                        .flatten(),
                }));
            }
            format.emit(serde_json::json!({ "tools": rows }), || {
                for row in &rows {
                    let name = row["tool"].as_str().unwrap_or_default();
                    if row["installed"].as_bool().unwrap_or(false) {
                        let version = row["version"].as_str().unwrap_or("unknown");
                        println!("  {name} {version}");
                    } else {
                        println!("  {name} (not installed — `pv tool install {name}`)");
                    }
                }
            })?;
        }
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

fn cmd_doctor(format: Format) -> Result<ExitCode> {
    let findings = doctor::run()?;
    let (report, healthy) = doctor::report(&findings);
    format.emit(
        serde_json::json!({
            "healthy": healthy,
            "findings": findings
                .iter()
                .map(|finding| serde_json::json!({
                    "level": finding.level.as_str(),
                    "headline": finding.headline,
                    "advice": finding.advice,
                }))
                .collect::<Vec<_>>(),
        }),
        || print!("{report}"),
    )?;
    Ok(if healthy {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}
