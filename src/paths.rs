//! Where pv keeps its state on disk.
//!
//! Everything lives under one root so that uninstalling pv is `rm -rf` of a
//! single directory. `PV_HOME` names it; otherwise it follows the XDG Base
//! Directory convention, `$XDG_DATA_HOME/pv`, falling back to
//! `~/.local/share/pv` (see [`home`] for the exceptions):
//!
//! ```text
//! ~/.local/share/pv/
//!   versions/<version>/bin/php     extracted runtimes
//!   shims/php                      real files on PATH
//!   cache/                         downloaded tarballs
//!   config.toml                    default version + resolve strategy
//! ```

use std::ffi::OsString;
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
    let home = std::env::var_os(HOME_VARIABLE).with_context(|| {
        format!("{HOME_VARIABLE} is not set, so pv cannot find its state directory — set PV_HOME")
    })?;
    Ok(default_home(
        Path::new(&home),
        std::env::var_os("XDG_DATA_HOME"),
        cfg!(windows),
    ))
}

/// Where pv keeps its state when `PV_HOME` does not say.
///
/// `$XDG_DATA_HOME/pv`, or `~/.local/share/pv` when that is unset — the same
/// convention the other version managers follow. Two exceptions:
///
/// - An existing `~/.pv` is still used. That is where earlier versions of pv
///   kept everything, and moving the default must not strand the PHPs already
///   installed there, or the shim directory a profile already puts on `PATH`.
/// - Windows keeps `%USERPROFILE%\.pv`. XDG is not a Windows convention.
fn default_home(user_home: &Path, xdg_data_home: Option<OsString>, windows: bool) -> PathBuf {
    let legacy = user_home.join(".pv");
    if windows || legacy.is_dir() {
        return legacy;
    }
    // The spec says a relative XDG_DATA_HOME is invalid and must be ignored.
    match xdg_data_home.map(PathBuf::from) {
        Some(data) if data.is_absolute() => data.join("pv"),
        _ => user_home.join(".local").join("share").join("pv"),
    }
}

/// The variable that names the user's home directory.
///
/// Windows does not set `HOME`. Some shells there invent one, and following
/// it would give pv a different state directory depending on which shell
/// started it.
const HOME_VARIABLE: &str = if cfg!(windows) { "USERPROFILE" } else { "HOME" };

pub fn versions_dir() -> Result<PathBuf> {
    Ok(home()?.join("versions"))
}

pub fn version_dir(version: &str) -> Result<PathBuf> {
    Ok(versions_dir()?.join(version))
}

pub fn shims_dir() -> Result<PathBuf> {
    Ok(home()?.join("shims"))
}

/// Phars shared by every installed PHP — Composer, PIE. A phar is bytecode,
/// so there is nothing version-specific to duplicate.
pub fn tools_dir() -> Result<PathBuf> {
    Ok(home()?.join("tools"))
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

/// Mark a file runnable.
///
/// Windows has no executable bit — a file runs because of its extension — so
/// there is nothing to set there.
pub fn make_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .with_context(|| format!("could not make {} executable", path.display()))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_xdg_data_home() {
        let user = tempfile::tempdir().unwrap();
        let data = user.path().join("data");
        assert_eq!(
            default_home(user.path(), Some(data.clone().into()), false),
            data.join("pv")
        );
    }

    #[test]
    fn falls_back_to_local_share() {
        let user = tempfile::tempdir().unwrap();
        let expected = user.path().join(".local/share/pv");
        assert_eq!(default_home(user.path(), None, false), expected);
        // Unset and empty mean the same thing, and a relative path is invalid.
        assert_eq!(default_home(user.path(), Some("".into()), false), expected);
        assert_eq!(
            default_home(user.path(), Some("relative/data".into()), false),
            expected
        );
    }

    #[test]
    fn an_existing_dot_pv_is_not_stranded() {
        let user = tempfile::tempdir().unwrap();
        std::fs::create_dir(user.path().join(".pv")).unwrap();
        let data = user.path().join("data");
        assert_eq!(
            default_home(user.path(), Some(data.into()), false),
            user.path().join(".pv")
        );
    }

    #[test]
    fn windows_keeps_its_own_convention() {
        let user = tempfile::tempdir().unwrap();
        let data = user.path().join("data");
        assert_eq!(
            default_home(user.path(), Some(data.into()), true),
            user.path().join(".pv")
        );
    }
}
