# Security

## Reporting a vulnerability

Email **kucherenko.web@gmail.com** with "Loupe security" in the subject, or use
[GitHub private vulnerability reporting](https://github.com/serhii-kucherenko/loupe/security/advisories/new).
Please do not open a public issue for a vulnerability.

Expect an acknowledgement within 7 days. If a fix is needed, we will agree a disclosure
date with you rather than publish first.

## What Loupe collects, and why it matters

This is the part worth reading before you adopt it. Loupe exists to capture context from a
running application, so by design it handles data that would be sensitive in the wrong build.

An annotation bundle contains:

| Data | Notes |
|---|---|
| A cropped screenshot of the element you picked | Whatever was on screen is in the image, including any real data the app was displaying |
| Recent network events | Method, **URL**, status code, duration. See the warning below |
| Console and error output | May contain identifiers the app logged |
| Your typed or spoken comment | Free text |
| App name, version, commit, platform, environment | Build identification |

**Loupe does not capture request or response bodies, and does not capture request headers.**
That is deliberate: bodies and headers are where credentials usually live.

### The known sharp edge: URLs

Full request URLs are recorded, including query strings. If your API puts a token, a session
id, or personal data in a query parameter, it lands in the bundle.

Until per-product redaction ships, treat every bundle store as if it contains credentials.
If your API does this, do not enable Loupe against it. Redaction is tracked as a known gap
rather than quietly assumed away.

## Rules for using it safely

1. **Dev and staging builds only. Never ship Loupe in a production build.** Guard it behind
   a build configuration flag, not a runtime setting a user could reach.
2. **Do not point it at production data.** Screenshots of a real customer's screen are the
   customer's data, and now they are in a bundle folder and an issue tracker.
3. **Keep the bundle store private.** `FileTransport` writes to the local filesystem;
   `HTTPTransport` needs an authenticated endpoint on a private network or behind a token.
   Never a public bucket.
4. **Set a retention window.** Bundles should be deleted once they have become tickets.
   They accumulate screenshots otherwise.
5. **Treat the intake token as a secret.** It lives in a non-production build, which limits
   the blast radius, but it is still a credential. Rotate by shipping a new build.

## Supported versions

Pre-1.0. Only the latest tag receives fixes. Once 1.0 ships, this table will list the
supported minor versions.
