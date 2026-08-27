//! Tarball extraction.
//!
//! Artifacts wrap their contents in a single top-level directory, so the first
//! path component is stripped on the way out — the same shape `tar
//! --strip-components 1` produces.

use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, bail};
use flate2::read::GzDecoder;
use tar::Archive;

pub fn extract_stripped(tarball: &Path, dest: &Path) -> Result<()> {
    let file = std::fs::File::open(tarball)
        .with_context(|| format!("could not open {}", tarball.display()))?;
    let mut archive = Archive::new(GzDecoder::new(file));
    archive.set_preserve_permissions(true);
    std::fs::create_dir_all(dest).with_context(|| format!("could not create {}", dest.display()))?;

    let mut extracted = 0usize;
    for entry in archive
        .entries()
        .with_context(|| format!("{} is not a readable tar.gz", tarball.display()))?
    {
        let mut entry = entry.with_context(|| format!("{} is corrupt", tarball.display()))?;
        let path = entry.path()?.into_owned();
        let Some(relative) = strip_first_component(&path)? else {
            continue;
        };
        let out = dest.join(&relative);
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("could not create {}", parent.display()))?;
        }
        entry
            .unpack(&out)
            .with_context(|| format!("could not extract {} to {}", path.display(), out.display()))?;
        extracted += 1;
    }

    if extracted == 0 {
        bail!("{} contained no files", tarball.display());
    }
    Ok(())
}

/// Drop the wrapper directory, refusing anything that would escape the
/// destination — a tarball is untrusted input even when its hash checks out.
fn strip_first_component(path: &Path) -> Result<Option<PathBuf>> {
    let mut components = path.components();
    for component in path.components() {
        match component {
            Component::Normal(_) | Component::CurDir => {}
            _ => bail!(
                "refusing to extract `{}` — the archive contains an absolute or \
                 parent-directory path",
                path.display()
            ),
        }
    }
    components.next();
    let relative: PathBuf = components.collect();
    if relative.as_os_str().is_empty() {
        return Ok(None);
    }
    Ok(Some(relative))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tarball(dir: &Path, entries: &[(&str, &[u8])]) -> PathBuf {
        let path = dir.join("archive.tar.gz");
        let file = std::fs::File::create(&path).unwrap();
        let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
        let mut builder = tar::Builder::new(encoder);
        for (name, body) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(body.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder.append_data(&mut header, name, *body).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap();
        path
    }

    #[test]
    fn strips_the_wrapper_directory() {
        let dir = tempfile::tempdir().unwrap();
        let archive = tarball(
            dir.path(),
            &[
                ("php-8.4.3/bin/php", b"binary"),
                ("php-8.4.3/etc/php.ini", b"; ini"),
            ],
        );
        let dest = dir.path().join("out");
        extract_stripped(&archive, &dest).unwrap();
        assert_eq!(std::fs::read(dest.join("bin/php")).unwrap(), b"binary");
        assert!(dest.join("etc/php.ini").is_file());
    }

    /// `tar::Builder` refuses to write a traversing path, so the header is
    /// filled in by hand — which is exactly how a hostile archive arrives.
    fn hostile_tarball(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join("hostile.tar.gz");
        let file = std::fs::File::create(&path).unwrap();
        let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
        let mut builder = tar::Builder::new(encoder);
        let body = b"nope";
        let mut header = tar::Header::new_gnu();
        header.as_gnu_mut().unwrap().name[..name.len()].copy_from_slice(name.as_bytes());
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        builder.append(&header, &body[..]).unwrap();
        builder.into_inner().unwrap().finish().unwrap();
        path
    }

    #[test]
    fn refuses_paths_that_escape_the_destination() {
        let dir = tempfile::tempdir().unwrap();
        let archive = hostile_tarball(dir.path(), "php-8.4.3/../../evil");
        let dest = dir.path().join("out");
        assert!(extract_stripped(&archive, &dest).is_err());
        assert!(!dir.path().join("evil").exists());
    }

    #[test]
    fn refuses_absolute_paths() {
        let dir = tempfile::tempdir().unwrap();
        let archive = hostile_tarball(dir.path(), "/etc/pv-evil");
        assert!(extract_stripped(&archive, &dir.path().join("out")).is_err());
    }

    #[test]
    fn an_empty_archive_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let archive = tarball(dir.path(), &[]);
        assert!(extract_stripped(&archive, &dir.path().join("out")).is_err());
    }
}
