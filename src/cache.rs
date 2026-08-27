//! The download cache.
//!
//! Tarballs are kept after installation so a reinstall or a second machine
//! account does not re-download tens of megabytes. Nothing prunes them
//! automatically: deleting a file a user might be about to reuse is a poor
//! trade for disk that is rarely scarce, so pruning is a command they run.

use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::installs;
use crate::paths;

pub struct Entry {
    pub path: PathBuf,
    pub bytes: u64,
    /// Whether an installed version records this file as its source.
    pub in_use: bool,
}

pub fn entries() -> Result<Vec<Entry>> {
    let dir = paths::cache_dir()?;
    let read = match std::fs::read_dir(&dir) {
        Ok(read) => read,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err).with_context(|| format!("could not read {}", dir.display())),
    };

    // A tarball is in use when an installed version was installed from it.
    let mut referenced: Vec<String> = Vec::new();
    for version in installs::installed()? {
        if let Some(record) = installs::read_record(&version)? {
            referenced.push(record.file);
        }
    }

    let mut entries = Vec::new();
    for entry in read.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_string();
        entries.push(Entry {
            bytes: entry.metadata().map(|meta| meta.len()).unwrap_or(0),
            in_use: referenced.contains(&name),
            path,
        });
    }
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(entries)
}

pub fn total_bytes(entries: &[Entry]) -> u64 {
    entries.iter().map(|entry| entry.bytes).sum()
}

/// Remove cached tarballs, returning what went and how much it freed.
///
/// `keep_in_use` spares the tarball each installed version came from — those
/// are what `pv doctor` re-hashes to detect a tampered cache, and what a
/// `--force` reinstall reuses instead of downloading again.
pub fn remove(keep_in_use: bool) -> Result<(usize, u64)> {
    let mut removed = 0;
    let mut freed = 0;
    for entry in entries()? {
        if keep_in_use && entry.in_use {
            continue;
        }
        std::fs::remove_file(&entry.path)
            .with_context(|| format!("could not remove {}", entry.path.display()))?;
        removed += 1;
        freed += entry.bytes;
    }
    Ok((removed, freed))
}
