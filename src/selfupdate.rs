//! `pv self update` — replace this binary with the newest published one.

use anyhow::{Context, Result, bail};

use crate::config::Config;
use crate::manifest::Manifest;
use crate::version::Version;
use crate::{archive, net, paths, platform};

pub fn update(force: bool) -> Result<()> {
    let current: Version = env!("CARGO_PKG_VERSION").parse()?;
    let platform = platform::current()?;
    let config = Config::load()?;
    let manifest = Manifest::fetch(&config.manifest_url())?;

    let Some((latest, artifact)) = manifest.newest_pv(&platform) else {
        bail!("the manifest publishes no pv build for {platform}");
    };
    if latest <= current && !force {
        println!("pv {current} is already the newest published build");
        return Ok(());
    }
    let expected = artifact.verified_sha256()?;

    let cached = paths::cache_dir()?.join(&artifact.file);
    let _ = std::fs::remove_file(&cached);
    let downloaded = net::download(&artifact.url, &cached, artifact.size)?;
    if downloaded != expected {
        let _ = std::fs::remove_file(&cached);
        bail!(
            "{} does not match the manifest — expected sha256 {expected}, got {downloaded}. \
             pv was not replaced.",
            artifact.file
        );
    }

    let staging = paths::cache_dir()?.join(format!(".pv-{latest}.incoming"));
    let _ = std::fs::remove_dir_all(&staging);
    archive::extract_stripped(&cached, &staging)?;
    let incoming = staging.join("bin").join("pv");
    if !incoming.is_file() {
        let _ = std::fs::remove_dir_all(&staging);
        bail!("{} does not contain bin/pv", artifact.file);
    }

    // Swap in place. Replacing a running binary by rename is safe on Unix —
    // the running process keeps its open inode.
    let target = std::env::current_exe().context("could not determine pv's own path")?;
    let beside = target.with_extension("incoming");
    std::fs::copy(&incoming, &beside).with_context(|| {
        format!(
            "could not stage the new pv next to {} — is that directory writable?",
            target.display()
        )
    })?;
    make_executable(&beside)?;
    std::fs::rename(&beside, &target)
        .with_context(|| format!("could not replace {}", target.display()))?;
    let _ = std::fs::remove_dir_all(&staging);

    println!("pv {current} -> {latest}");
    Ok(())
}

fn make_executable(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = std::fs::metadata(path)?.permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions)
        .with_context(|| format!("could not make {} executable", path.display()))
}
