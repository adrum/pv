//! The local inventory: which versions are on this machine, and what they were
//! installed from.

use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::paths;
use crate::version::Version;

/// What `pv install` recorded about the artifact a version came from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtifactRecord {
    pub version: String,
    pub platform: String,
    pub file: String,
    pub sha256: String,
    pub url: String,
    /// Unix seconds, for `pv doctor` and for humans reading the file.
    pub installed_at: u64,
}

/// Installed versions, oldest first.
///
/// A directory only counts when it holds a `bin/php`; a half-extracted or
/// hand-made directory is not a usable install and must not be listed as one.
pub fn installed() -> Result<Vec<Version>> {
    let dir = paths::versions_dir()?;
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err).with_context(|| format!("could not read {}", dir.display())),
    };

    let mut versions = Vec::new();
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(version) = name.parse::<Version>() else {
            continue;
        };
        if entry.path().join("bin").join("php").is_file() {
            versions.push(version);
        }
    }
    versions.sort();
    Ok(versions)
}

pub fn is_installed(version: &Version) -> Result<bool> {
    Ok(paths::version_dir(&version.to_string())?
        .join("bin")
        .join("php")
        .is_file())
}

/// Path to a command inside an installed version, whether or not it exists.
pub fn binary_path(version: &Version, command: &str) -> Result<PathBuf> {
    Ok(paths::version_dir(&version.to_string())?
        .join("bin")
        .join(command))
}

/// Commands an installed version actually provides.
pub fn commands(version: &Version) -> Result<Vec<String>> {
    let bin = paths::version_dir(&version.to_string())?.join("bin");
    let entries = match std::fs::read_dir(&bin) {
        Ok(entries) => entries,
        Err(_) => return Ok(Vec::new()),
    };
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_file())
        .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
        .collect();
    names.sort();
    Ok(names)
}

pub fn read_record(version: &Version) -> Result<Option<ArtifactRecord>> {
    let path = paths::artifact_record(&version.to_string())?;
    match std::fs::read_to_string(&path) {
        Ok(raw) => Ok(serde_json::from_str(&raw).ok()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err).with_context(|| format!("could not read {}", path.display())),
    }
}

pub fn write_record(version: &Version, record: &ArtifactRecord) -> Result<()> {
    let path = paths::artifact_record(&version.to_string())?;
    let body = serde_json::to_string_pretty(record)?;
    std::fs::write(&path, format!("{body}\n"))
        .with_context(|| format!("could not write {}", path.display()))
}

pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn remove(version: &Version) -> Result<()> {
    let dir = paths::version_dir(&version.to_string())?;
    std::fs::remove_dir_all(&dir)
        .with_context(|| format!("could not remove {}", dir.display()))
}
