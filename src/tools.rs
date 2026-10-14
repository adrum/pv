//! PHP tools that ship as phars — Composer and PIE.
//!
//! pv does not *bundle* these. Their versions have nothing to do with PHP's,
//! they update on their own schedule, and vendoring them would mean owning
//! their release cycles and fighting their `self-update`. What pv does is
//! fetch the official phar, verify it against the hash its publisher
//! publishes, and make sure it runs under whichever PHP the current directory
//! resolves to — which is the part that is otherwise fiddly and easy to get
//! wrong.
//!
//! Each phar is stored once, in the pv home's `tools/`, and shared by every
//! installed PHP. A phar is bytecode; there is nothing version-specific about
//! it.

use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::exit::{self, Failed};
use crate::{net, paths};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Tool {
    /// The dependency manager
    Composer,
    /// The PHP Installer for Extensions, PECL's successor
    Pie,
}

impl Tool {
    pub fn name(self) -> &'static str {
        match self {
            Tool::Composer => "composer",
            Tool::Pie => "pie",
        }
    }

    pub fn home(self) -> &'static str {
        match self {
            Tool::Composer => "https://getcomposer.org",
            Tool::Pie => "https://github.com/php/pie",
        }
    }

    pub fn all() -> [Tool; 2] {
        [Tool::Composer, Tool::Pie]
    }

    pub fn from_name(name: &str) -> Option<Tool> {
        Self::all().into_iter().find(|tool| tool.name() == name)
    }

    /// Where the phar lives once installed.
    pub fn path(self) -> Result<PathBuf> {
        Ok(paths::tools_dir()?.join(format!("{}.phar", self.name())))
    }

    fn record_path(self) -> Result<PathBuf> {
        Ok(paths::tools_dir()?.join(format!(".{}.json", self.name())))
    }
}

/// What was installed, and what it was verified against.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub tool: String,
    pub version: String,
    pub url: String,
    pub sha256: String,
    pub installed_at: u64,
}

/// A phar to download, and the hash its publisher says it should have.
struct Download {
    version: String,
    url: String,
    sha256: String,
}

/// Ask each project where its current phar is and what it hashes to.
///
/// Both publish a hash next to the download, so verification fails closed the
/// same way a PHP artifact does. Neither hash is fetched from a different
/// origin than the file it protects, which is the same limitation pv's own
/// manifest has and is documented as such.
fn resolve(tool: Tool) -> Result<Download> {
    match tool {
        Tool::Composer => {
            // Composer publishes composer.phar alongside a .sha256sum in the
            // usual `<hash>  <filename>` shape.
            let base = "https://getcomposer.org/download/latest-stable";
            let url = format!("{base}/composer.phar");
            let sums = net::fetch_text(&format!("{url}.sha256sum"))?;
            let sha256 = sums
                .split_whitespace()
                .next()
                .filter(|hash| is_sha256(hash))
                .ok_or_else(|| {
                    Failed::new(
                        exit::VERIFICATION,
                        format!(
                            "getcomposer.org did not publish a usable sha256 for \
                             composer.phar (got `{}`) — refusing to install it unverified",
                            sums.trim()
                        ),
                    )
                })?
                .to_string();
            Ok(Download {
                // Resolved from the phar itself after download; the URL is a
                // moving "latest-stable" pointer with no version in it.
                version: String::new(),
                url,
                sha256,
            })
        }
        Tool::Pie => {
            // PIE publishes no checksum file, but GitHub exposes a digest for
            // every release asset, which is the same trust model as the hash
            // in pv's own manifest.
            let release = net::fetch_text("https://api.github.com/repos/php/pie/releases/latest")?;
            let release: serde_json::Value = serde_json::from_str(&release)
                .context("the php/pie release feed is not usable JSON")?;
            let version = release
                .get("tag_name")
                .and_then(|tag| tag.as_str())
                .unwrap_or("unknown")
                .to_string();

            let asset = release
                .get("assets")
                .and_then(|assets| assets.as_array())
                .and_then(|assets| {
                    assets.iter().find(|asset| {
                        asset.get("name").and_then(|n| n.as_str()) == Some("pie.phar")
                    })
                })
                .ok_or_else(|| {
                    Failed::new(
                        exit::NOT_PUBLISHED,
                        "the latest php/pie release publishes no pie.phar",
                    )
                })?;

            let sha256 = asset
                .get("digest")
                .and_then(|digest| digest.as_str())
                .and_then(|digest| digest.strip_prefix("sha256:"))
                .filter(|hash| is_sha256(hash))
                .ok_or_else(|| {
                    Failed::new(
                        exit::VERIFICATION,
                        "php/pie's release does not publish a sha256 digest for pie.phar — \
                         refusing to install it unverified",
                    )
                })?
                .to_string();

            let url = asset
                .get("browser_download_url")
                .and_then(|url| url.as_str())
                .unwrap_or_default()
                .to_string();
            Ok(Download {
                version,
                url,
                sha256,
            })
        }
    }
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit())
}

pub struct Outcome {
    pub tool: Tool,
    pub version: String,
    pub path: PathBuf,
}

pub fn install(tool: Tool) -> Result<Outcome> {
    let dir = paths::tools_dir()?;
    paths::ensure_dir(&dir)?;

    // One installer at a time per tool, for the same reason installs are
    // locked: two of them would write the same file.
    let _lock = crate::lock::acquire(&dir, tool.name(), &format!("installing {}", tool.name()))?;

    let download = resolve(tool)?;
    let path = tool.path()?;
    let downloaded = net::download(&download.url, &path, None)?;

    if downloaded != download.sha256 {
        let _ = std::fs::remove_file(&path);
        return Err(Failed::new(
            exit::VERIFICATION,
            format!(
                "{}.phar does not match the hash {} publishes — expected {}, got {}. \
                 Nothing was installed.",
                tool.name(),
                tool.home(),
                download.sha256,
                downloaded
            ),
        ));
    }

    paths::make_executable(&path)?;

    // Composer's download URL carries no version, so ask the phar itself once
    // it is verified — the answer belongs in the record either way.
    let version = if download.version.is_empty() {
        detect_version(tool, &path).unwrap_or_else(|| "unknown".to_string())
    } else {
        download.version.clone()
    };

    let record = Record {
        tool: tool.name().to_string(),
        version: version.clone(),
        url: download.url,
        sha256: download.sha256,
        installed_at: crate::installs::now_unix(),
    };
    std::fs::write(
        tool.record_path()?,
        format!("{}\n", serde_json::to_string_pretty(&record)?),
    )?;

    Ok(Outcome {
        tool,
        version,
        path,
    })
}

/// Ask a phar its version, using whichever PHP resolves here.
fn detect_version(tool: Tool, phar: &std::path::Path) -> Option<String> {
    let php = crate::current_php().ok()?;
    let output = std::process::Command::new(php)
        .arg(phar)
        .arg("--version")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    // "Composer version 2.8.12 2026-01-01 ..." / "PIE 1.5.1 ..."
    text.split_whitespace()
        .find(|word| word.chars().next().is_some_and(|c| c.is_ascii_digit()) && word.contains('.'))
        .map(|version| version.trim_start_matches('v').to_string())
        .or_else(|| Some(format!("{} (version unknown)", tool.name())))
}

pub fn read_record(tool: Tool) -> Result<Option<Record>> {
    match std::fs::read_to_string(tool.record_path()?) {
        Ok(raw) => Ok(serde_json::from_str(&raw).ok()),
        Err(_) => Ok(None),
    }
}

pub fn is_installed(tool: Tool) -> Result<bool> {
    Ok(tool.path()?.is_file())
}

pub fn uninstall(tool: Tool) -> Result<()> {
    let path = tool.path()?;
    std::fs::remove_file(&path).with_context(|| format!("could not remove {}", path.display()))?;
    let _ = std::fs::remove_file(tool.record_path()?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for tool in Tool::all() {
            assert_eq!(Tool::from_name(tool.name()), Some(tool));
        }
        assert_eq!(Tool::from_name("pecl"), None);
    }

    #[test]
    fn only_a_real_sha256_counts() {
        assert!(is_sha256(&"a".repeat(64)));
        assert!(!is_sha256(&"a".repeat(63)));
        assert!(!is_sha256(&"z".repeat(64)));
        assert!(!is_sha256(""));
    }
}
