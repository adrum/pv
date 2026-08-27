//! The release manifest: every published artifact with its sha256.
//!
//! ```json
//! {
//!   "schema": 1,
//!   "php": {
//!     "8.4.3": {
//!       "darwin-arm64": {
//!         "file": "php-8.4.3-darwin-arm64.tar.gz",
//!         "url": "https://…/php-8.4.3-darwin-arm64.tar.gz",
//!         "sha256": "…",
//!         "size": 41231234
//!       }
//!     }
//!   },
//!   "pv": { "0.1.0": { "darwin-arm64": { … } } }
//! }
//! ```
//!
//! Integrity checking here **fails closed**. An entry with a missing, empty or
//! malformed hash is an error — never a reason to skip verification. Guarding
//! the check with "if a hash is present" is a one-line change that quietly
//! disables integrity for every malformed entry.
//!
//! Be clear-eyed about what this buys: the hash ships inside the manifest it
//! protects, so anyone able to rewrite the manifest rewrites both. It defends
//! the artifact given a trustworthy manifest — tamper evidence independent of
//! the hosting account needs a signed manifest, which is a later step.

use std::collections::BTreeMap;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::net;
use crate::version::Version;

#[derive(Debug, Clone, Deserialize)]
pub struct Artifact {
    pub file: String,
    pub url: String,
    pub sha256: String,
    #[serde(default)]
    pub size: Option<u64>,
}

impl Artifact {
    /// The hash, or an error explaining that the entry cannot be trusted.
    pub fn verified_sha256(&self) -> Result<&str> {
        let sha = self.sha256.trim();
        if sha.is_empty() {
            bail!(
                "the manifest entry for {} has no sha256 — refusing to install an \
                 unverifiable artifact",
                self.file
            );
        }
        if sha.len() != 64 || !sha.chars().all(|c| c.is_ascii_hexdigit()) {
            bail!(
                "the manifest entry for {} has a malformed sha256 (`{sha}`) — refusing to \
                 install an unverifiable artifact",
                self.file
            );
        }
        Ok(sha)
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Manifest {
    pub schema: Option<u32>,
    /// version → platform → artifact
    pub php: BTreeMap<String, BTreeMap<String, Artifact>>,
    /// pv's own releases, for `pv self update`.
    pub pv: BTreeMap<String, BTreeMap<String, Artifact>>,
}

/// Manifest schema this build understands.
pub const SUPPORTED_SCHEMA: u32 = 1;

impl Manifest {
    pub fn fetch(url: &str) -> Result<Self> {
        let body = net::fetch_text(url)
            .with_context(|| format!("could not fetch the pv manifest from {url}"))?;
        Self::parse(&body).with_context(|| format!("the manifest at {url} is not usable"))
    }

    pub fn parse(body: &str) -> Result<Self> {
        let manifest: Manifest = serde_json::from_str(body)?;
        if let Some(schema) = manifest.schema
            && schema > SUPPORTED_SCHEMA
        {
            bail!(
                "this manifest uses schema {schema} and pv understands {SUPPORTED_SCHEMA} — \
                 run `pv self update`"
            );
        }
        Ok(manifest)
    }

    /// Versions published for a platform, oldest first.
    pub fn php_versions(&self, platform: &str) -> Vec<Version> {
        let mut versions: Vec<Version> = self
            .php
            .iter()
            .filter(|(_, builds)| builds.contains_key(platform))
            .filter_map(|(version, _)| version.parse().ok())
            .collect();
        versions.sort();
        versions
    }

    pub fn php_artifact(&self, version: &Version, platform: &str) -> Result<&Artifact> {
        let builds = self.php.get(&version.to_string()).with_context(|| {
            format!("PHP {version} is not published — run `pv list --remote` to see what is")
        })?;
        builds.get(platform).with_context(|| {
            let available: Vec<&str> = builds.keys().map(String::as_str).collect();
            format!(
                "PHP {version} is not published for {platform} — published for: {}",
                available.join(", ")
            )
        })
    }

    /// Newest pv release for a platform, if any.
    pub fn newest_pv(&self, platform: &str) -> Option<(Version, &Artifact)> {
        self.pv
            .iter()
            .filter_map(|(version, builds)| {
                Some((version.parse::<Version>().ok()?, builds.get(platform)?))
            })
            .max_by_key(|(version, _)| *version)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BODY: &str = r#"{
      "schema": 1,
      "php": {
        "8.4.3": {
          "darwin-arm64": {
            "file": "php-8.4.3-darwin-arm64.tar.gz",
            "url": "https://example.test/php-8.4.3-darwin-arm64.tar.gz",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }
        },
        "8.2.20": {
          "linux-x86_64": {
            "file": "php-8.2.20-linux-x86_64.tar.gz",
            "url": "https://example.test/php-8.2.20-linux-x86_64.tar.gz",
            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          }
        }
      }
    }"#;

    #[test]
    fn lists_only_versions_built_for_the_platform() {
        let manifest = Manifest::parse(BODY).unwrap();
        assert_eq!(
            manifest.php_versions("darwin-arm64"),
            vec![Version::new(8, 4, 3)]
        );
        assert!(manifest.php_versions("linux-arm64").is_empty());
    }

    #[test]
    fn missing_platform_build_names_what_exists() {
        let manifest = Manifest::parse(BODY).unwrap();
        let error = manifest
            .php_artifact(&Version::new(8, 4, 3), "linux-arm64")
            .unwrap_err()
            .to_string();
        assert!(error.contains("darwin-arm64"), "{error}");
    }

    #[test]
    fn verification_fails_closed_on_a_bad_hash() {
        let artifact = |sha: &str| Artifact {
            file: "php-8.4.3-darwin-arm64.tar.gz".into(),
            url: "https://example.test/x".into(),
            sha256: sha.into(),
            size: None,
        };
        assert!(artifact("").verified_sha256().is_err());
        assert!(artifact("   ").verified_sha256().is_err());
        assert!(artifact("abc123").verified_sha256().is_err());
        assert!(artifact(&"z".repeat(64)).verified_sha256().is_err());
        assert!(artifact(&"a".repeat(64)).verified_sha256().is_ok());
    }

    #[test]
    fn an_entry_without_a_hash_field_does_not_parse() {
        let body = r#"{"php":{"8.4.3":{"darwin-arm64":{"file":"x","url":"y"}}}}"#;
        assert!(Manifest::parse(body).is_err());
    }

    #[test]
    fn a_newer_schema_asks_for_an_update() {
        let body = r#"{"schema": 99, "php": {}}"#;
        let error = Manifest::parse(body).unwrap_err().to_string();
        assert!(error.contains("pv self update"), "{error}");
    }
}
