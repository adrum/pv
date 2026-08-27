//! Which PHP runs here.
//!
//! Resolution order, first match wins:
//!
//! 1. `PV_PHP_VERSION`
//! 2. `.php-version` in the current directory
//! 3. `.php-version` in an ancestor directory (recursive strategy only)
//! 4. `composer.json` platform/require constraint — a *hint*
//! 5. the configured default
//! 6. newest installed
//!
//! Two rules hold everything together. Resolution is **read-only**: it never
//! installs, never writes, never touches the working directory, which is what
//! makes shims cheap and lets scripts ask "what would run here?". And it
//! **falls back rather than fails**: an unpinned directory resolves to the
//! newest installed version, because a version manager that refuses to run
//! `php -v` is experienced as broken.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::config::Strategy;
use crate::version::{Selector, Version, best_matching_constraint};

pub const VERSION_FILE: &str = ".php-version";

/// Why this version was chosen. Carried through so `which` and `doctor` can
/// explain themselves — "8.4.3 (newest installed)" answers a question that
/// "8.4.3" leaves open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    Environment,
    VersionFile(PathBuf),
    Composer(PathBuf, String),
    Default,
    NewestInstalled,
}

impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Source::Environment => write!(f, "PV_PHP_VERSION"),
            Source::VersionFile(path) => write!(f, "{}", path.display()),
            Source::Composer(path, constraint) => {
                write!(f, "{} ({constraint})", path.display())
            }
            Source::Default => write!(f, "pv default"),
            Source::NewestInstalled => write!(f, "newest installed"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolution {
    pub version: Version,
    pub source: Source,
}

/// Everything resolution is allowed to look at. Passing it in keeps the
/// algorithm testable without a real `$HOME` or real installs.
pub struct Request<'a> {
    pub cwd: &'a Path,
    pub installed: &'a [Version],
    pub strategy: Strategy,
    pub default: Option<&'a str>,
    pub environment: Option<&'a str>,
}

pub fn resolve(request: &Request<'_>) -> Result<Resolution> {
    // 1. Explicit override. An override that names an uninstalled version is
    //    an error, not a fall-through: the user said exactly what they wanted.
    if let Some(raw) = request.environment.map(str::trim).filter(|s| !s.is_empty()) {
        let selector: Selector = raw
            .parse()
            .with_context(|| format!("PV_PHP_VERSION is set to `{raw}`"))?;
        return pick(request, &selector, Source::Environment);
    }

    // 2 & 3. .php-version, here then upward.
    for dir in search_path(request) {
        let file = dir.join(VERSION_FILE);
        if let Some(raw) = read_version_file(&file)? {
            let selector: Selector = raw.parse().with_context(|| {
                format!("{} does not contain a usable version", file.display())
            })?;
            return pick(request, &selector, Source::VersionFile(file));
        }
    }

    // 4. composer.json, as a hint only: it holds a constraint rather than a
    //    version, so it selects among what is installed and never installs.
    for dir in search_path(request) {
        let file = dir.join("composer.json");
        if let Some(constraint) = read_composer_constraint(&file)?
            && let Some(version) = best_matching_constraint(&constraint, request.installed)
        {
            return Ok(Resolution {
                version,
                source: Source::Composer(file, constraint),
            });
        }
    }

    // 5. The configured default.
    if let Some(raw) = request.default.map(str::trim).filter(|s| !s.is_empty()) {
        let selector: Selector = raw
            .parse()
            .with_context(|| format!("the pv default is set to `{raw}`"))?;
        return pick(request, &selector, Source::Default);
    }

    // 6. Newest installed.
    match request.installed.iter().max() {
        Some(version) => Ok(Resolution {
            version: *version,
            source: Source::NewestInstalled,
        }),
        None => bail!("no PHP installed — run `pv install 8.4` to get one"),
    }
}

fn pick(request: &Request<'_>, selector: &Selector, source: Source) -> Result<Resolution> {
    match selector.best(request.installed) {
        Some(version) => Ok(Resolution { version, source }),
        None => bail!(
            "PHP {selector} is required by {source} but is not installed — \
             run `pv install {selector}`"
        ),
    }
}

/// Directories to search, nearest first.
fn search_path(request: &Request<'_>) -> Vec<PathBuf> {
    match request.strategy {
        Strategy::Local => vec![request.cwd.to_path_buf()],
        Strategy::Recursive => request.cwd.ancestors().map(Path::to_path_buf).collect(),
    }
}

/// First non-empty, non-comment line of a `.php-version`.
pub fn read_version_file(path: &Path) -> Result<Option<String>> {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) if err.kind() == std::io::ErrorKind::IsADirectory => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("could not read {}", path.display())),
    };
    Ok(raw
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_string))
}

/// `config.platform.php` first, then `require.php`.
///
/// Platform config is what Composer itself resolves against, so it is the
/// better signal when both are present. A malformed composer.json is not an
/// error here — it is only ever a hint.
fn read_composer_constraint(path: &Path) -> Result<Option<String>> {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return Ok(None),
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return Ok(None);
    };
    let constraint = json
        .pointer("/config/platform/php")
        .or_else(|| json.pointer("/require/php"))
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    Ok(constraint)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(major: u64, minor: u64, patch: u64) -> Version {
        Version::new(major, minor, patch)
    }

    struct Fixture {
        dir: tempfile::TempDir,
        installed: Vec<Version>,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                dir: tempfile::tempdir().unwrap(),
                installed: vec![v(7, 4, 33), v(8, 2, 20), v(8, 4, 3), v(8, 4, 12)],
            }
        }

        fn write(&self, relative: &str, body: &str) -> PathBuf {
            let path = self.dir.path().join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, body).unwrap();
            path
        }

        fn sub(&self, relative: &str) -> PathBuf {
            let path = self.dir.path().join(relative);
            std::fs::create_dir_all(&path).unwrap();
            path
        }

        fn request<'a>(&'a self, cwd: &'a Path, environment: Option<&'a str>) -> Request<'a> {
            Request {
                cwd,
                installed: &self.installed,
                strategy: Strategy::Recursive,
                default: None,
                environment,
            }
        }
    }

    #[test]
    fn environment_wins_over_everything() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.2.20\n");
        let resolution = resolve(&fixture.request(&fixture.sub(""), Some("8.4.3"))).unwrap();
        assert_eq!(resolution.version, v(8, 4, 3));
        assert_eq!(resolution.source, Source::Environment);
    }

    #[test]
    fn version_file_in_cwd() {
        let fixture = Fixture::new();
        let file = fixture.write(".php-version", "8.2.20\n");
        let resolution = resolve(&fixture.request(&fixture.sub(""), None)).unwrap();
        assert_eq!(resolution.version, v(8, 2, 20));
        assert_eq!(resolution.source, Source::VersionFile(file));
    }

    #[test]
    fn a_line_resolves_to_the_newest_patch() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.4\n");
        assert_eq!(resolve(&fixture.request(&fixture.sub(""), None)).unwrap().version, v(8, 4, 12));
    }

    #[test]
    fn prefixed_version_files_still_work() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "php-8.2.20\n");
        assert_eq!(resolve(&fixture.request(&fixture.sub(""), None)).unwrap().version, v(8, 2, 20));
    }

    #[test]
    fn comments_and_blank_lines_are_skipped() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "\n# pinned for the legacy app\n7.4.33\n");
        assert_eq!(resolve(&fixture.request(&fixture.sub(""), None)).unwrap().version, v(7, 4, 33));
    }

    #[test]
    fn recursive_walks_up_and_local_does_not() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.2.20\n");

        let cwd = fixture.sub("packages/api");
        let mut request = fixture.request(&cwd, None);
        assert_eq!(resolve(&request).unwrap().version, v(8, 2, 20));

        request.strategy = Strategy::Local;
        // Nothing pinned in reach, so it falls back rather than failing.
        let resolution = resolve(&request).unwrap();
        assert_eq!(resolution.version, v(8, 4, 12));
        assert_eq!(resolution.source, Source::NewestInstalled);
    }

    #[test]
    fn nearest_version_file_wins() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.2.20\n");
        fixture.write("packages/api/.php-version", "7.4.33\n");
        let resolution = resolve(&fixture.request(&fixture.sub("packages/api"), None)).unwrap();
        assert_eq!(resolution.version, v(7, 4, 33));
    }

    #[test]
    fn every_version_file_is_checked_before_any_composer_json() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.2.20\n");
        fixture.write("packages/api/composer.json", r#"{"require":{"php":"^8.4"}}"#);
        let resolution = resolve(&fixture.request(&fixture.sub("packages/api"), None)).unwrap();
        assert_eq!(resolution.version, v(8, 2, 20));
    }

    #[test]
    fn composer_platform_beats_require() {
        let fixture = Fixture::new();
        fixture.write(
            "composer.json",
            r#"{"require":{"php":"^8.4"},"config":{"platform":{"php":"8.2.20"}}}"#,
        );
        let resolution = resolve(&fixture.request(&fixture.sub(""), None)).unwrap();
        assert_eq!(resolution.version, v(8, 2, 20));
        assert!(matches!(resolution.source, Source::Composer(_, _)));
    }

    #[test]
    fn composer_never_fails_resolution() {
        let fixture = Fixture::new();
        // Nothing installed satisfies this, and the file itself is broken
        // further down — either way the hint is skipped, not fatal.
        fixture.write("composer.json", r#"{"require":{"php":"^9.0"}}"#);
        assert_eq!(resolve(&fixture.request(&fixture.sub(""), None)).unwrap().version, v(8, 4, 12));

        fixture.write("composer.json", "{ not json");
        assert_eq!(resolve(&fixture.request(&fixture.sub(""), None)).unwrap().version, v(8, 4, 12));
    }

    #[test]
    fn default_is_used_before_newest() {
        let fixture = Fixture::new();
        let cwd = fixture.sub("");
        let mut request = fixture.request(&cwd, None);
        request.default = Some("8.2");
        let resolution = resolve(&request).unwrap();
        assert_eq!(resolution.version, v(8, 2, 20));
        assert_eq!(resolution.source, Source::Default);
    }

    #[test]
    fn pinned_but_missing_names_the_next_action() {
        let fixture = Fixture::new();
        fixture.write(".php-version", "8.3.1\n");
        let error = resolve(&fixture.request(&fixture.sub(""), None)).unwrap_err().to_string();
        assert!(error.contains("pv install 8.3.1"), "{error}");
    }

    #[test]
    fn nothing_installed_names_the_next_action() {
        let fixture = Fixture::new();
        let request = Request {
            cwd: fixture.dir.path(),
            installed: &[],
            strategy: Strategy::Recursive,
            default: None,
            environment: None,
        };
        let error = resolve(&request).unwrap_err().to_string();
        assert!(error.contains("pv install 8.4"), "{error}");
    }
}
