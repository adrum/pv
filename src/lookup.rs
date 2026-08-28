//! Finding commands on `PATH`, the way a shell would.

use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::shims;

/// First executable `command` on `PATH`.
pub fn on_path(command: &str) -> Option<PathBuf> {
    entries()
        .into_iter()
        .map(|dir| dir.join(command))
        .find(|candidate| is_executable(candidate))
}

/// First executable `command` on `PATH` that is not one of pv's own shims.
///
/// Every shim ends in `pv run <command>`, so a search that accepted one would
/// hand `pv run` back to itself and spin forever. Identity is the only
/// reliable test — a shim is a real file with a real name, and the marker line
/// is what distinguishes it.
pub fn on_path_excluding_shims(command: &str) -> Result<Option<PathBuf>> {
    for dir in entries() {
        let candidate = dir.join(command);
        if !is_executable(&candidate) {
            continue;
        }
        if shims::is_pv_shim(&candidate)? {
            continue;
        }
        return Ok(Some(candidate));
    }
    Ok(None)
}

pub fn entries() -> Vec<PathBuf> {
    std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default()
}

pub fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn executable(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn a_shim_is_never_returned_as_a_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let shim_dir = dir.path().join("shims");
        let real_dir = dir.path().join("bin");
        executable(
            &shim_dir.join("composer"),
            &shims::shim_body(Path::new("/opt/pv"), "composer"),
        );
        executable(&real_dir.join("composer"), "#!/bin/sh\necho real\n");

        // Both are on PATH, with the shim first — exactly the layout pv's own
        // init produces.
        let path = std::env::join_paths([&shim_dir, &real_dir]).unwrap();
        temp_env_path(&path, || {
            assert_eq!(on_path("composer"), Some(shim_dir.join("composer")));
            assert_eq!(
                on_path_excluding_shims("composer").unwrap(),
                Some(real_dir.join("composer"))
            );
        });
    }

    #[test]
    fn nothing_on_path_is_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = std::env::join_paths([dir.path()]).unwrap();
        temp_env_path(&path, || {
            assert_eq!(on_path("composer"), None);
            assert_eq!(on_path_excluding_shims("composer").unwrap(), None);
        });
    }

    /// PATH is process-wide, so these tests run one at a time behind a lock.
    fn temp_env_path(value: &std::ffi::OsStr, body: impl FnOnce()) {
        use std::sync::Mutex;
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK.lock().unwrap_or_else(|err| err.into_inner());

        let previous = std::env::var_os("PATH");
        // SAFETY: serialized by LOCK, and restored before the guard drops.
        unsafe { std::env::set_var("PATH", value) };
        body();
        match previous {
            Some(previous) => unsafe { std::env::set_var("PATH", previous) },
            None => unsafe { std::env::remove_var("PATH") },
        }
    }
}
