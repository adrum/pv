//! Where pv keeps its state on disk.
//!
//! Everything lives under one root (`PV_HOME`, default `~/.pv`) so that
//! uninstalling pv is `rm -rf` of a single directory:
//!
//! ```text
//! ~/.pv/
//!   versions/<version>/bin/php     extracted runtimes
//!   shims/php                      real files on PATH
//!   cache/                         downloaded tarballs
//!   config.toml                    default version + resolve strategy
//! ```

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// Root of all pv state.
pub fn home() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("PV_HOME") {
        let dir = PathBuf::from(dir);
        if dir.as_os_str().is_empty() {
            anyhow::bail!("PV_HOME is set but empty — unset it or point it at a directory");
        }
        return Ok(dir);
    }
    let home = std::env::var_os("HOME")
        .context("HOME is not set, so pv cannot find its state directory — set PV_HOME")?;
    Ok(PathBuf::from(home).join(".pv"))
}

pub fn versions_dir() -> Result<PathBuf> {
    Ok(home()?.join("versions"))
}

pub fn version_dir(version: &str) -> Result<PathBuf> {
    Ok(versions_dir()?.join(version))
}

pub fn shims_dir() -> Result<PathBuf> {
    Ok(home()?.join("shims"))
}

pub fn cache_dir() -> Result<PathBuf> {
    Ok(home()?.join("cache"))
}

pub fn config_path() -> Result<PathBuf> {
    Ok(home()?.join("config.toml"))
}

/// Record of the artifact a version was installed from, written next to the
/// extracted tree so `pv doctor` can report tampering and `pv install` can
/// detect a rebuilt-but-same-version artifact.
pub fn artifact_record(version: &str) -> Result<PathBuf> {
    Ok(version_dir(version)?.join(".pv-artifact.json"))
}

pub fn ensure_dir(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path).with_context(|| format!("could not create {}", path.display()))
}
