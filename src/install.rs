//! Downloading, verifying and unpacking a PHP.

use anyhow::{Context, Result, bail};

use crate::config::Config;
use crate::installs::{self, ArtifactRecord};
use crate::manifest::Manifest;
use crate::net;
use crate::paths;
use crate::version::{Selector, Version};
use crate::{archive, lock, platform, shims};

pub struct Outcome {
    pub version: Version,
    /// False when the requested version was already installed from the same
    /// artifact and nothing was downloaded.
    pub changed: bool,
}

pub fn install(selector: &Selector, force: bool) -> Result<Outcome> {
    let config = Config::load()?;
    let platform = platform::current()?;
    let manifest = Manifest::fetch(&config.manifest_url())?;

    let available = manifest.php_versions(&platform);
    let Some(version) = selector.best(&available) else {
        bail!(
            "no published PHP {selector} for {platform} — run `pv list --remote` to see \
             what is available"
        );
    };
    let artifact = manifest.php_artifact(&version, &platform)?;
    let expected = artifact.verified_sha256()?;

    // Everything below writes to paths derived from the version — the cache
    // entry, the staging tree, the version directory itself — so one holder
    // at a time, per version.
    let _lock = lock::acquire(
        &paths::versions_dir()?,
        &version.to_string(),
        &format!("installing PHP {version}"),
    )?;

    if !force
        && installs::is_installed(&version)?
        && let Some(record) = installs::read_record(&version)?
        && record.sha256 == expected
    {
        return Ok(Outcome {
            version,
            changed: false,
        });
    }

    // Reuse a cached tarball only when it hashes to what the manifest says.
    let cached = paths::cache_dir()?.join(&artifact.file);
    let downloaded = if cached.is_file() && net::sha256_file(&cached)? == expected {
        eprintln!("  using cached {}", artifact.file);
        expected.to_string()
    } else {
        let _ = std::fs::remove_file(&cached);
        net::download(&artifact.url, &cached, artifact.size)?
    };

    if downloaded != expected {
        let _ = std::fs::remove_file(&cached);
        bail!(
            "{} does not match the manifest — expected sha256 {expected}, got {downloaded}. \
             Nothing was installed.",
            artifact.file
        );
    }

    let target = paths::version_dir(&version.to_string())?;
    let staging = paths::versions_dir()?.join(format!(".{version}.incoming"));
    let _ = std::fs::remove_dir_all(&staging);
    archive::extract_stripped(&cached, &staging)?;

    if !staging.join("bin").join("php").is_file() {
        let _ = std::fs::remove_dir_all(&staging);
        bail!(
            "{} does not contain bin/php — the artifact is not a pv PHP build",
            artifact.file
        );
    }

    // Swap late, so a failure above leaves the previous install untouched.
    if target.exists() {
        let previous = paths::versions_dir()?.join(format!(".{version}.previous"));
        let _ = std::fs::remove_dir_all(&previous);
        std::fs::rename(&target, &previous)
            .with_context(|| format!("could not move the existing {version} aside"))?;
        let result = std::fs::rename(&staging, &target);
        if result.is_err() {
            let _ = std::fs::rename(&previous, &target);
            result.with_context(|| format!("could not install {version}"))?;
        }
        let _ = std::fs::remove_dir_all(&previous);
    } else {
        std::fs::rename(&staging, &target)
            .with_context(|| format!("could not install {version} into {}", target.display()))?;
    }

    installs::write_record(
        &version,
        &ArtifactRecord {
            version: version.to_string(),
            platform: platform.clone(),
            file: artifact.file.clone(),
            sha256: expected.to_string(),
            url: artifact.url.clone(),
            installed_at: installs::now_unix(),
            // Recorded from the tree as extracted, so doctor can later speak
            // about what is installed rather than about the tarball it came in.
            files: installs::hash_tree(&version)?,
        },
    )?;

    shims::sync()?;

    Ok(Outcome {
        version,
        changed: true,
    })
}
