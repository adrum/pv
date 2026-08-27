//! Host platform identification, in the form used by artifact names:
//! `php-8.4.3-darwin-arm64.tar.gz`.

use anyhow::{Result, bail};

pub fn current() -> Result<String> {
    if let Ok(forced) = std::env::var("PV_PLATFORM")
        && !forced.trim().is_empty()
    {
        return Ok(forced.trim().to_string());
    }
    let os = match std::env::consts::OS {
        "macos" => "darwin",
        "linux" => "linux",
        other => bail!(
            "pv has no builds for {other} yet — supported platforms are darwin and linux \
             (see the platform table in the README)"
        ),
    };
    let arch = match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => bail!("pv has no builds for {other} yet"),
    };
    Ok(format!("{os}-{arch}"))
}
