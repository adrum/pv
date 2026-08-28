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
use crate::{installs, lookup, net, paths, platform, shims};

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

    if let Some(finding) = composer_check()? {
        findings.push(finding);
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
    match lookup::on_path("php") {
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

/// Whether the Composer on PATH will actually run under pv's PHP.
///
/// pv does not ship Composer and should not — but it does own which PHP a PHP
/// tool runs under, and this is the case people get wrong without noticing. A
/// `composer.phar` with a `#!/usr/bin/env php` shebang resolves through PATH
/// and lands on pv's shim, which is correct. A package manager's Composer is
/// usually a wrapper with that package manager's PHP written into it as an
/// absolute path, and it will keep using that PHP no matter what pv resolves,
/// silently, forever.
fn composer_check() -> Result<Option<Finding>> {
    let Some(composer) = lookup::on_path("composer") else {
        return Ok(None);
    };
    let Some(bound) = php_bound_into(&composer)? else {
        return Ok(Some(Finding::ok(format!(
            "composer on PATH runs under the resolved php ({})",
            composer.display()
        ))));
    };

    let home = paths::home()?;
    if bound.starts_with(&home) {
        return Ok(Some(Finding::ok(format!(
            "composer on PATH is bound to pv's php ({})",
            composer.display()
        ))));
    }

    Ok(Some(Finding::warn(
        format!(
            "composer at {} is bound to {} and ignores pv",
            composer.display(),
            bound.display()
        ),
        "that composer will keep using that PHP whatever pv resolves — run it as \
         `pv run composer …`, or install composer.phar (its `#!/usr/bin/env php` \
         shebang resolves through pv)",
    )))
}

/// The absolute PHP path baked into a wrapper script, if there is one.
///
/// Reads only the head of the file: a phar is megabytes of binary, and the
/// interesting part of a wrapper is always in the first few lines.
fn php_bound_into(command: &Path) -> Result<Option<PathBuf>> {
    use std::io::Read as _;

    let Ok(mut file) = std::fs::File::open(command) else {
        return Ok(None);
    };
    let mut head = vec![0u8; 4096];
    let read = file.read(&mut head).unwrap_or(0);
    let head = String::from_utf8_lossy(&head[..read]);
    if !head.starts_with("#!") {
        return Ok(None);
    }

    // An absolute path whose last component is php or php<version>, anywhere
    // in the wrapper: `#!/opt/homebrew/opt/php@8.3/bin/php` and
    // `exec "/usr/local/Cellar/php/8.3.0/bin/php" …` are the same problem.
    for token in head.split(|c: char| c.is_whitespace() || c == '"' || c == '\'') {
        if !token.starts_with('/') {
            continue;
        }
        let path = Path::new(token);
        let is_php = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| name == "php" || name.starts_with("php8") || name.starts_with("php7"))
            .unwrap_or(false);
        if is_php && path.is_file() {
            return Ok(Some(path.to_path_buf()));
        }
    }
    Ok(None)
}

fn install_checks(installed: &[crate::version::Version]) -> Result<Vec<Finding>> {
    let mut findings = Vec::new();
    for version in installed {
        let php = installs::binary_path(version, "php")?;
        if !lookup::is_executable(&php) {
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
