//! `~/.pv/config.toml` — user preferences, plain text and hand-editable.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::paths;

/// How far up the tree pv looks for a `.php-version`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Strategy {
    /// Only the current directory.
    Local,
    /// Walk up to the filesystem root. Monorepos want this, so it is default.
    #[default]
    Recursive,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// Version used when nothing else pins one.
    pub default: Option<String>,
    pub strategy: Strategy,
    /// Where `pv install` looks for artifacts. Overridden by `PV_MANIFEST_URL`.
    pub manifest_url: Option<String>,
}

/// Where artifacts are published, in order of precedence: `PV_MANIFEST_URL`,
/// then `manifest_url` in the config file, then this.
///
/// The manifest lives under a rolling release tag rather than `latest`, so
/// cutting a pv release cannot move the runtime manifest out from under
/// installed clients. Set `PV_DEFAULT_MANIFEST_URL` at build time to point a
/// fork or a mirror somewhere else.
pub const DEFAULT_MANIFEST_URL: &str = match option_env!("PV_DEFAULT_MANIFEST_URL") {
    Some(url) => url,
    None => "https://github.com/adrum/pv/releases/download/runtimes/manifest.json",
};

impl Config {
    pub fn load() -> Result<Self> {
        let path = paths::config_path()?;
        let raw = match std::fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => {
                return Err(err).with_context(|| format!("could not read {}", path.display()));
            }
        };
        toml::from_str(&raw).with_context(|| {
            format!(
                "{} is not valid pv config — fix it by hand or delete it to start over",
                path.display()
            )
        })
    }

    pub fn save(&self) -> Result<()> {
        let path = paths::config_path()?;
        paths::ensure_dir(&paths::home()?)?;
        let body = toml::to_string_pretty(self).context("could not serialize pv config")?;
        std::fs::write(&path, body).with_context(|| format!("could not write {}", path.display()))
    }

    pub fn manifest_url(&self) -> String {
        if let Ok(url) = std::env::var("PV_MANIFEST_URL")
            && !url.trim().is_empty()
        {
            return url;
        }
        self.manifest_url
            .clone()
            .unwrap_or_else(|| DEFAULT_MANIFEST_URL.to_string())
    }
}
