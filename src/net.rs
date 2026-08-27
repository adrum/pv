//! HTTP, kept deliberately small: fetch a document, or stream a file to disk
//! while hashing it.

use std::io::{IsTerminal, Read, Write};
use std::path::Path;

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

const USER_AGENT: &str = concat!("pv/", env!("CARGO_PKG_VERSION"));

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .user_agent(USER_AGENT)
        .timeout_global(Some(std::time::Duration::from_secs(300)))
        .build()
        .into()
}

pub fn fetch_text(url: &str) -> Result<String> {
    let mut response = agent()
        .get(url)
        .call()
        .with_context(|| format!("GET {url} failed"))?;
    response
        .body_mut()
        .read_to_string()
        .with_context(|| format!("could not read the response from {url}"))
}

/// Stream `url` into `dest`, returning the sha256 of what was written.
///
/// The download lands on a `.part` file and is only renamed into place once
/// the whole body has been read, so an interrupted download can never be
/// mistaken for a complete one.
pub fn download(url: &str, dest: &Path, expected_size: Option<u64>) -> Result<String> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;
    }
    let partial = dest.with_extension("part");

    let mut response = agent()
        .get(url)
        .call()
        .with_context(|| format!("GET {url} failed"))?;
    let total = response
        .headers()
        .get("content-length")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .or(expected_size);

    let mut reader = response.body_mut().as_reader();
    let mut file = std::fs::File::create(&partial)
        .with_context(|| format!("could not create {}", partial.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 128 * 1024];
    let mut written: u64 = 0;
    let mut progress = Progress::new(dest.file_name().unwrap_or_default().to_string_lossy());

    loop {
        let read = reader
            .read(&mut buffer)
            .with_context(|| format!("the download of {url} was interrupted"))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        file.write_all(&buffer[..read])
            .with_context(|| format!("could not write {}", partial.display()))?;
        written += read as u64;
        progress.update(written, total);
    }
    file.flush()?;
    drop(file);
    progress.finish(written);

    if let Some(total) = total
        && written != total
    {
        let _ = std::fs::remove_file(&partial);
        bail!("{url} ended early — got {written} bytes of {total}, try again");
    }

    std::fs::rename(&partial, dest).with_context(|| {
        format!(
            "could not move {} into place at {}",
            partial.display(),
            dest.display()
        )
    })?;
    Ok(hex(hasher.finalize().as_slice()))
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file =
        std::fs::File::open(path).with_context(|| format!("could not read {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 128 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex(hasher.finalize().as_slice()))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A one-line, redraw-in-place byte counter. Silent when stderr is not a
/// terminal so CI logs stay readable.
struct Progress {
    label: String,
    interactive: bool,
    last_tick: u64,
}

impl Progress {
    fn new(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            interactive: std::io::stderr().is_terminal(),
            last_tick: 0,
        }
    }

    fn update(&mut self, written: u64, total: Option<u64>) {
        if !self.interactive {
            return;
        }
        // Redraw every 512 KB rather than every chunk.
        if written - self.last_tick < 512 * 1024 {
            return;
        }
        self.last_tick = written;
        let progress = match total {
            Some(total) => format!("{} / {}", megabytes(written), megabytes(total)),
            None => megabytes(written),
        };
        eprint!("\r  downloading {} {progress}   ", self.label);
        let _ = std::io::stderr().flush();
    }

    fn finish(&self, written: u64) {
        if self.interactive {
            eprint!("\r\u{1b}[2K");
        }
        eprintln!("  downloaded {} ({})", self.label, megabytes(written));
    }
}

pub fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_048_576.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_match_the_reference_vector() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("empty");
        std::fs::write(&file, b"").unwrap();
        assert_eq!(
            sha256_file(&file).unwrap(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
