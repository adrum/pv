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
        "windows" => "windows",
        other => bail!(
            "pv has no builds for {other} yet — supported platforms are darwin, linux and \
             windows (see the platform table in the README)"
        ),
    };
    let arch = match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => bail!("pv has no builds for {other} yet"),
    };
    Ok(format!("{os}-{arch}"))
}

/// The file name of the executable called `name`: `php.exe` on Windows, `php`
/// everywhere else.
///
/// Every path to a binary goes through this. A lookup that forgets the suffix
/// does not fail on Windows, it just finds nothing.
pub fn exe(name: &str) -> String {
    with_suffix(name, std::env::consts::EXE_SUFFIX)
}

/// The command a file in a `bin` directory provides, if it provides one.
///
/// Where executables carry a suffix, only a file that has it is a command —
/// the DLLs sitting next to `php.exe` are not.
pub fn command_name(file: &str) -> Option<&str> {
    without_suffix(file, std::env::consts::EXE_SUFFIX)
}

fn with_suffix(name: &str, suffix: &str) -> String {
    if suffix.is_empty() || without_suffix(name, suffix).is_some() {
        return name.to_string();
    }
    format!("{name}{suffix}")
}

fn without_suffix<'a>(file: &'a str, suffix: &str) -> Option<&'a str> {
    if suffix.is_empty() {
        return Some(file);
    }
    let split = file.len().checked_sub(suffix.len())?;
    let (stem, tail) = (file.get(..split)?, file.get(split..)?);
    (!stem.is_empty() && tail.eq_ignore_ascii_case(suffix)).then_some(stem)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_suffix_is_added_once_and_only_where_there_is_one() {
        assert_eq!(with_suffix("php", ""), "php");
        assert_eq!(with_suffix("php", ".exe"), "php.exe");
        assert_eq!(with_suffix("php.exe", ".exe"), "php.exe");
        assert_eq!(with_suffix("PHP.EXE", ".exe"), "PHP.EXE");
    }

    #[test]
    fn only_executables_are_commands_where_they_carry_a_suffix() {
        assert_eq!(without_suffix("php-cgi", ""), Some("php-cgi"));
        assert_eq!(without_suffix("php-cgi.exe", ".exe"), Some("php-cgi"));
        assert_eq!(without_suffix("php8ts.dll", ".exe"), None);
        assert_eq!(without_suffix(".exe", ".exe"), None);
    }
}
