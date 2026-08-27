//! `pv doctor` — say plainly what is wrong and what to do about it.
//!
//! The checks here exist because each corresponding failure is silent: a
//! shadowed shim directory, a shell that cached a command location before the
//! shims existed, a version pinned but never installed. None of them announce
//! themselves; all of them look like "pv doesn't work".

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::config::Config;
use crate::resolve::{self, Request};
use crate::{installs, net, paths, platform, shims};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Ok,
    Warn,
    Problem,
}

impl Level {
    fn tag(self) -> &'static str {
        match self {
            Level::Ok => "ok      ",
            Level::Warn => "warn    ",
            Level::Problem => "problem ",
        }
    }
}

pub struct Finding {
    pub level: Level,
    pub headline: String,
    /// What to do about it. Printed indented under the headline.
    pub advice: Option<String>,
}

impl Finding {
    fn ok(headline: impl Into<String>) -> Self {
        Self {
            level: Level::Ok,
            headline: headline.into(),
            advice: None,
        }
    }

    fn warn(headline: impl Into<String>, advice: impl Into<String>) -> Self {
        Self {
            level: Level::Warn,
            headline: headline.into(),
            advice: Some(advice.into()),
        }
    }

    fn problem(headline: impl Into<String>, advice: impl Into<String>) -> Self {
        Self {
            level: Level::Problem,
            headline: headline.into(),
            advice: Some(advice.into()),
        }
    }
}

pub fn run() -> Result<Vec<Finding>> {
    let mut findings = Vec::new();
    let config = Config::load()?;

    findings.push(match platform::current() {
        Ok(platform) => Finding::ok(format!("platform {platform}")),
        Err(err) => Finding::problem(err.to_string(), "pv cannot install PHP on this platform"),
    });

    let home = paths::home()?;
    findings.push(home_check(&home));
    findings.extend(path_checks()?);

    let installed = installs::installed()?;
    if installed.is_empty() {
        findings.push(Finding::problem("no PHP installed", "run `pv install 8.4`"));
    } else {
        let list: Vec<String> = installed.iter().map(ToString::to_string).collect();
        findings.push(Finding::ok(format!(
            "{} installed: {}",
            installed.len(),
            list.join(", ")
        )));
        findings.extend(install_checks(&installed)?);
    }

    findings.push(resolution_check(&config, &installed)?);
    Ok(findings)
}

fn home_check(home: &Path) -> Finding {
    if !home.exists() {
        return Finding::warn(
            format!("{} does not exist yet", home.display()),
            "it is created on the first `pv install`",
        );
    }
    let probe = home.join(".pv-write-probe");
    match std::fs::write(&probe, b"") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            Finding::ok(format!("pv home {}", home.display()))
        }
        Err(err) => Finding::problem(
            format!("pv home {} is not writable ({err})", home.display()),
            "check its ownership, or point PV_HOME somewhere you own",
        ),
    }
}

fn path_checks() -> Result<Vec<Finding>> {
    let mut findings = Vec::new();
    let status = shims::path_status("php")?;

    if !status.on_path {
        findings.push(Finding::problem(
            format!("{} is not on PATH", status.shims.display()),
            format!(
                "add it, in front of everything else:\n      eval \"$(pv init zsh)\"\n    \
                 or add this line to your shell profile:\n      export PATH=\"{}:$PATH\"",
                status.shims.display()
            ),
        ));
    } else if status.shadowed_by.is_empty() {
        findings.push(Finding::ok(format!(
            "{} comes first on PATH",
            status.shims.display()
        )));
    } else {
        let owners: Vec<String> = status
            .shadowed_by
            .iter()
            .map(|path| path.display().to_string())
            .collect();
        findings.push(Finding::problem(
            format!("another php comes before pv's shims: {}", owners.join(", ")),
            format!(
                "move {} earlier in PATH, or remove the other php",
                status.shims.display()
            ),
        ));
    }

    // What the shell would actually run, which is the question users are
    // really asking. A stale shell hash shows up here as a path that does not
    // exist, or an old one.
    match which_on_path("php") {
        Some(found) if shims::is_pv_shim(&found)? => {
            findings.push(Finding::ok(format!(
                "php on PATH is pv's shim ({})",
                found.display()
            )));
        }
        Some(found) => findings.push(Finding::warn(
            format!("php on PATH is not a pv shim ({})", found.display()),
            "pv will not control that php — fix PATH order, then run `hash -r`",
        )),
        None => findings.push(Finding::warn(
            "no php on PATH",
            "install one with `pv install 8.4`, then run `hash -r` \
             (shells cache command locations, so a shell open since before the \
             install may still miss it)",
        )),
    }

    Ok(findings)
}

fn install_checks(installed: &[crate::version::Version]) -> Result<Vec<Finding>> {
    let mut findings = Vec::new();
    for version in installed {
        let php = installs::binary_path(version, "php")?;
        if !is_executable(&php) {
            findings.push(Finding::problem(
                format!("{version}: bin/php is not executable"),
                format!("reinstall it with `pv install {version} --force`"),
            ));
            continue;
        }
        match installs::read_record(version)? {
            None => findings.push(Finding::warn(
                format!("{version}: no artifact record"),
                format!(
                    "pv cannot tell what this was installed from — \
                     `pv install {version} --force` re-records it"
                ),
            )),
            Some(record) => {
                // What is installed, checked against what was installed. This
                // is the check that speaks about the tree on disk: a modified
                // bin/php verifies perfectly against the manifest, because the
                // manifest describes a tarball.
                let changed = installs::changed_files(version, &record)?;
                if !changed.is_empty() {
                    findings.push(Finding::problem(
                        format!("{version}: changed since install — {}", changed.join(", ")),
                        format!("reinstall with `pv install {version} --force`"),
                    ));
                }
                if record.files.is_empty() {
                    findings.push(Finding::warn(
                        format!("{version}: installed before pv recorded file hashes"),
                        format!(
                            "pv cannot tell whether this tree has been modified — \
                             `pv install {version} --force` records them"
                        ),
                    ));
                }

                // The recorded artifact hash is the tarball's, so it is checked
                // against the cached tarball while that is still around.
                let cached = paths::cache_dir()?.join(&record.file);
                if cached.is_file() && net::sha256_file(&cached)? != record.sha256 {
                    findings.push(Finding::problem(
                        format!(
                            "{version}: cached {} does not match its record",
                            record.file
                        ),
                        format!(
                            "delete {} and run `pv install {version} --force`",
                            cached.display()
                        ),
                    ));
                }
            }
        }
    }
    if findings.is_empty() {
        findings.push(Finding::ok("installed versions look intact"));
    }
    Ok(findings)
}

fn resolution_check(config: &Config, installed: &[crate::version::Version]) -> Result<Finding> {
    let cwd = std::env::current_dir()?;
    let environment = std::env::var("PV_PHP_VERSION").ok();
    let request = Request {
        cwd: &cwd,
        installed,
        strategy: config.strategy,
        default: config.default.as_deref(),
        environment: environment.as_deref(),
    };
    Ok(match resolve::resolve(&request) {
        Ok(resolution) => Finding::ok(format!(
            "here, php is {} (from {})",
            resolution.version, resolution.source
        )),
        Err(err) => Finding::problem(format!("here, php does not resolve: {err}"), "see above"),
    })
}

/// First `command` on PATH, the way a shell would find it.
pub fn which_on_path(command: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(command))
        .find(|candidate| is_executable(candidate))
}

pub fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Render findings, and whether anything is actually broken.
pub fn report(findings: &[Finding]) -> (String, bool) {
    let mut out = String::new();
    let mut healthy = true;
    for finding in findings {
        let _ = writeln!(out, "{}{}", finding.level.tag(), finding.headline);
        if let Some(advice) = &finding.advice {
            let _ = writeln!(out, "        {advice}");
        }
        if finding.level == Level::Problem {
            healthy = false;
        }
    }
    (out, healthy)
}
