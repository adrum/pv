//! `pv self update` — replace this binary with the newest published one.

use anyhow::{Context, Result, bail};

use crate::config::Config;
use crate::exit::{self, Failed};
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
        return Err(Failed::new(
            exit::VERIFICATION,
            format!(
                "{} does not match the manifest — expected sha256 {expected}, got \
                 {downloaded}. pv was not replaced.",
                artifact.file
            ),
        ));
    }

    let staging = paths::cache_dir()?.join(format!(".pv-{latest}.incoming"));
    let _ = std::fs::remove_dir_all(&staging);
    archive::extract_stripped(&cached, &staging)?;
    let pv = platform::exe("pv");
    let incoming = staging.join("bin").join(&pv);
    if !incoming.is_file() {
        let _ = std::fs::remove_dir_all(&staging);
        bail!("{} does not contain bin/{pv}", artifact.file);
    }

    let target = std::env::current_exe().context("could not determine pv's own path")?;
    let beside = target.with_extension("incoming");
    std::fs::copy(&incoming, &beside).with_context(|| {
        format!(
            "could not stage the new pv next to {} — is that directory writable?",
            target.display()
        )
    })?;
    paths::make_executable(&beside)?;
    swap_in(&beside, &target).with_context(|| format!("could not replace {}", target.display()))?;
    let _ = std::fs::remove_dir_all(&staging);

    println!("pv {current} -> {latest}");
    Ok(())
}

/// Swap in place. Replacing a running binary by rename is safe on Unix — the
/// running process keeps its open inode.
#[cfg(not(windows))]
fn swap_in(new: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
    std::fs::rename(new, target)
}

/// Windows will not replace or delete a running executable, but it will
/// rename one. So the running pv steps aside and the new one takes its name.
/// The old file cannot be removed while this process lives; the next update
/// clears it away.
#[cfg(windows)]
fn swap_in(new: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
    let old = target.with_extension("old");
    let _ = std::fs::remove_file(&old);
    std::fs::rename(target, &old)?;
    if let Err(err) = std::fs::rename(new, target) {
        let _ = std::fs::rename(&old, target);
        return Err(err);
    }
    let _ = std::fs::remove_file(&old);
    Ok(())
}
