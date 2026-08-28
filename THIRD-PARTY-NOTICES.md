# Third-party notices

`pv` itself is MIT licensed (see `LICENSE`) and has no runtime dependencies.
This file is about the **PHP artifacts** `pv` downloads, which are a different
matter: each is a binary distribution of PHP plus roughly fifty statically
linked libraries.

Every artifact carries the full license text of everything linked into it,
under `licenses/` inside the tarball — installed at
`~/.pv/versions/<version>/licenses/`. That directory is generated during the
build, and the build fails rather than shipping without it.

## What is linked in

PHP itself is under the PHP License. The libraries span permissive licenses
(MIT, BSD, Apache-2.0, ISC, zlib, PostgreSQL, OpenLDAP, ImageMagick's own) and
copyleft ones. The copyleft components are the ones that need a decision
rather than a note:

| Component | License | Why it matters here |
|---|---|---|
| gmp | LGPL-3.0 or GPL-2.0 (dual) | statically linked |
| gettext (libintl) | LGPL | statically linked |
| libiconv | LGPL | statically linked |
| libheif | LGPL | statically linked, via imagick |
| libde265 | LGPL | statically linked, via imagick |

## The open question

The LGPL permits linking, including static linking, but conditions
distribution of a statically linked binary on the recipient being able to
relink the work against a modified version of the library. Shipping the
license text — which these artifacts now do — is necessary but not by itself
sufficient for that condition.

The options, in rough order of effort:

1. **Document a relink path.** Every source is pinned and every build step is
   in `build/`, so a determined recipient can rebuild. Whether that satisfies
   the relink condition for a *static* link is exactly the part worth a
   lawyer's opinion rather than a maintainer's.
2. **Publish the object files** alongside each artifact, which is the
   traditional way to satisfy it unambiguously.
3. **Drop the LGPL components.** gmp powers `ext/gmp`; gettext powers
   `ext/gettext`; libiconv underpins `ext/iconv`; libheif and libde265 give
   imagick HEIF support. Each removal costs a documented feature.

This is unresolved, deliberately and visibly, rather than assumed away. If you
are relying on these artifacts in a context where that matters, read the
license texts in the artifact and take your own advice.
