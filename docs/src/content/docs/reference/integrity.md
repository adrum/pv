---
title: Integrity and licensing
description: What is verified, what that buys, and what ships inside an artifact.
---

## Verification

Every artifact is published with its sha256 in `manifest.json`, and pv checks
it before extracting. Verification **fails closed**: an entry with a missing,
empty or malformed hash is an error, not a reason to skip the check. Guarding
the check with "if a hash is present" is a one-line change that quietly
disables integrity for every malformed entry.

Extraction refuses any archive path that would escape the destination, and the
new tree is swapped into place only after it unpacks — so a failed install
leaves the previous version untouched.

## What that actually buys

Be clear-eyed: the hash ships inside the manifest it protects, so anyone able
to rewrite the manifest rewrites both. It defends the artifact **given a
trustworthy manifest**.

Tamper evidence independent of the hosting account needs a signed manifest with
the public key in the client binary. That is not in this release, and saying so
is more useful than implying otherwise.

## After installation

`pv install` records the sha256 of every executable and shared object next to
the extracted tree, so `pv doctor` can report a tree that changed since it was
installed:

```
problem 8.4.21: changed since install — bin/php
        reinstall with `pv install 8.4.21 --force`
```

The artifact hash covers the tarball, which says nothing about the tree once it
is on disk — a modified `bin/php` verifies perfectly against a manifest,
because the manifest describes an archive.

`etc/php.ini` is deliberately not hashed: it is meant to be edited, and
reporting a hand-tuned `memory_limit` as tampering would train people to ignore
the check.

## Upstream selection

Waves build a patch only once it is at least 24 hours old. That narrows the
window in which a compromised or immediately-yanked upstream release gets
picked up, and costs nothing when upstream released last week. Since the client
resolves `latest` against the published manifest rather than upstream tags, the
age gate applies to everything it can install.

## Licensing

pv itself is MIT. The artifacts are a different matter: each is a binary
distribution of PHP plus roughly fifty statically linked libraries.

Every artifact carries the full license text of everything linked into it, at
`~/.pv/versions/<version>/licenses/`. The build fails rather than shipping
without them.

Several components are LGPL — gmp, gettext, libiconv, libheif, libde265 — and
the LGPL conditions distributing a *statically linked* binary on the recipient
being able to relink against a modified library. Shipping the license text is
necessary but not by itself sufficient for that. See
[THIRD-PARTY-NOTICES.md](https://github.com/adrum/pv/blob/main/THIRD-PARTY-NOTICES.md),
which records the question as open rather than assuming it away.
