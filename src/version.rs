//! Version parsing, ordering and constraint matching.
//!
//! Two distinct things live here: a concrete `Version` (what is installed) and
//! a `Selector` (what the user or a file asked for — `8.4`, `8.4.3`, `latest`).

use std::cmp::Ordering;
use std::fmt;
use std::str::FromStr;

use anyhow::{Result, bail};

/// A concrete PHP version: always major.minor.patch once installed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl Version {
    pub fn new(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    /// The `8.4` line this version belongs to.
    pub fn line(&self) -> (u64, u64) {
        (self.major, self.minor)
    }

    pub fn to_semver(self) -> semver::Version {
        semver::Version::new(self.major, self.minor, self.patch)
    }
}

impl FromStr for Version {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        let s = normalize(s);
        let mut parts = s.split('.');
        let mut next = |what: &str| -> Result<u64> {
            match parts.next() {
                Some(p) if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => Ok(p.parse()?),
                _ => bail!("`{s}` is not a version — expected {what}, as in 8.4.3"),
            }
        };
        let major = next("a major number")?;
        let minor = next("a minor number")?;
        let patch = next("a patch number")?;
        if parts.next().is_some() {
            bail!("`{s}` has too many parts — expected major.minor.patch, as in 8.4.3");
        }
        Ok(Version::new(major, minor, patch))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// What was asked for, which is not always a concrete version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    /// The newest version available.
    Latest,
    /// A line: `8.4` means the newest 8.4.x.
    Line(u64, u64),
    /// An exact version: `8.4.3`.
    Exact(Version),
}

impl Selector {
    /// The newest candidate this selector accepts.
    pub fn best<'a, I>(&self, candidates: I) -> Option<Version>
    where
        I: IntoIterator<Item = &'a Version>,
    {
        candidates
            .into_iter()
            .filter(|v| self.matches(v))
            .max()
            .copied()
    }

    pub fn matches(&self, version: &Version) -> bool {
        match self {
            Selector::Latest => true,
            Selector::Line(major, minor) => version.line() == (*major, *minor),
            Selector::Exact(exact) => version == exact,
        }
    }
}

impl FromStr for Selector {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        let s = normalize(s);
        if s.eq_ignore_ascii_case("latest") {
            return Ok(Selector::Latest);
        }
        let parts: Vec<&str> = s.split('.').collect();
        let numeric = |p: &str| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit());
        match parts.as_slice() {
            [major, minor] if numeric(major) && numeric(minor) => {
                Ok(Selector::Line(major.parse()?, minor.parse()?))
            }
            [major, minor, patch] if numeric(major) && numeric(minor) && numeric(patch) => Ok(
                Selector::Exact(Version::new(major.parse()?, minor.parse()?, patch.parse()?)),
            ),
            _ => bail!("`{s}` is not a version — try `8.4`, `8.4.3` or `latest`"),
        }
    }
}

impl fmt::Display for Selector {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Selector::Latest => write!(f, "latest"),
            Selector::Line(major, minor) => write!(f, "{major}.{minor}"),
            Selector::Exact(v) => write!(f, "{v}"),
        }
    }
}

/// Strip anything that makes a version string not a version string.
///
/// A `php-` prefix leaking into output looks like a bug and breaks
/// copy-paste, so it is stripped on the way in and never written back out.
fn normalize(s: &str) -> &str {
    let s = s.trim();
    let s = s.strip_prefix("php-").unwrap_or(s);
    let s = s.strip_prefix("php").unwrap_or(s);
    s.strip_prefix('v').unwrap_or(s).trim()
}

/// Newest installed version satisfying a Composer-style constraint.
///
/// Composer constraints are not semver requirements — the parts that overlap
/// (`^8.2`, `>=8.1 <8.4`, `8.2.*`) cover essentially every real
/// `require.php`, and the alternation operator is handled here. Anything that
/// still fails to parse yields `None`: the constraint is only ever a hint, so
/// a constraint pv cannot read means "no opinion", never an error.
pub fn best_matching_constraint(constraint: &str, candidates: &[Version]) -> Option<Version> {
    let alternatives: Vec<semver::VersionReq> = constraint
        .split("||")
        .filter_map(|alt| semver::VersionReq::parse(&to_semver_req(alt)).ok())
        .collect();
    if alternatives.is_empty() {
        return None;
    }
    candidates
        .iter()
        .filter(|v| {
            let semver = v.to_semver();
            alternatives.iter().any(|req| req.matches(&semver))
        })
        .max()
        .copied()
}

/// Translate one Composer constraint into the semver crate's dialect.
///
/// The dialects agree on `^`, `~`, ranges and wildcards, and disagree on a
/// bare version: Composer's `8.2.20` means exactly 8.2.20, while semver reads
/// it as `^8.2.20`. Left alone, a `platform.php` of `8.2.20` would happily
/// select 8.4 — the opposite of what the file says.
fn to_semver_req(alternative: &str) -> String {
    let alternative = alternative.trim();
    let bare =
        !alternative.is_empty() && alternative.chars().all(|c| c.is_ascii_digit() || c == '.');
    let alternative = if bare {
        format!("={alternative}")
    } else {
        alternative.to_string()
    };
    // Composer separates range parts with spaces; semver wants commas.
    alternative
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(major: u64, minor: u64, patch: u64) -> Version {
        Version::new(major, minor, patch)
    }

    #[test]
    fn parses_exact_versions() {
        assert_eq!("8.4.3".parse::<Version>().unwrap(), v(8, 4, 3));
    }

    #[test]
    fn strips_php_prefixes() {
        assert_eq!("php-8.4.3".parse::<Version>().unwrap(), v(8, 4, 3));
        assert_eq!("php8.4.3".parse::<Version>().unwrap(), v(8, 4, 3));
        assert_eq!(" v8.4.3\n".parse::<Version>().unwrap(), v(8, 4, 3));
    }

    #[test]
    fn rejects_nonsense() {
        assert!("8.4".parse::<Version>().is_err());
        assert!("8.4.3.1".parse::<Version>().is_err());
        assert!("eight".parse::<Version>().is_err());
        assert!("".parse::<Version>().is_err());
    }

    #[test]
    fn orders_numerically_not_lexically() {
        let mut all = vec![v(8, 4, 9), v(8, 4, 10), v(8, 10, 1), v(7, 4, 33)];
        all.sort();
        assert_eq!(all, vec![v(7, 4, 33), v(8, 4, 9), v(8, 4, 10), v(8, 10, 1)]);
    }

    #[test]
    fn selector_parsing() {
        assert_eq!("latest".parse::<Selector>().unwrap(), Selector::Latest);
        assert_eq!("8.4".parse::<Selector>().unwrap(), Selector::Line(8, 4));
        assert_eq!(
            "8.4.3".parse::<Selector>().unwrap(),
            Selector::Exact(v(8, 4, 3))
        );
        assert!("8".parse::<Selector>().is_err());
    }

    #[test]
    fn selector_picks_newest_match() {
        let all = [v(8, 3, 20), v(8, 4, 1), v(8, 4, 12), v(8, 5, 0)];
        assert_eq!(Selector::Line(8, 4).best(&all), Some(v(8, 4, 12)));
        assert_eq!(Selector::Latest.best(&all), Some(v(8, 5, 0)));
        assert_eq!(Selector::Exact(v(8, 4, 1)).best(&all), Some(v(8, 4, 1)));
        assert_eq!(Selector::Line(7, 4).best(&all), None);
    }

    #[test]
    fn composer_constraints() {
        let all = [v(8, 1, 30), v(8, 2, 20), v(8, 3, 15), v(8, 4, 3)];
        assert_eq!(best_matching_constraint("^8.2", &all), Some(v(8, 4, 3)));
        assert_eq!(best_matching_constraint("~8.2.0", &all), Some(v(8, 2, 20)));
        assert_eq!(
            best_matching_constraint(">=8.1 <8.3", &all),
            Some(v(8, 2, 20))
        );
        assert_eq!(best_matching_constraint("8.3.*", &all), Some(v(8, 3, 15)));
        // A bare version is exact in Composer, not a caret range.
        assert_eq!(best_matching_constraint("8.2.20", &all), Some(v(8, 2, 20)));
        assert_eq!(best_matching_constraint("8.3", &all), Some(v(8, 3, 15)));
        assert_eq!(
            best_matching_constraint("~8.1.0 || ~8.2.0", &all),
            Some(v(8, 2, 20))
        );
    }

    #[test]
    fn unreadable_constraint_is_no_opinion_not_an_error() {
        let all = [v(8, 4, 3)];
        assert_eq!(best_matching_constraint("nonsense", &all), None);
        assert_eq!(best_matching_constraint("^9.0", &all), None);
    }
}
