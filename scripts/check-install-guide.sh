#!/usr/bin/env bash
#
# Builds what `docs/agent-install.md` tells an adopter to write, against this working
# tree. If the guide drifts from the API, this fails.
#
#   bash scripts/check-install-guide.sh
#
# The guide is the first thing a new adopter runs, and prose cannot be compiled. Every
# other page in this repo is checked by something; this one was checked by nobody, and
# a wrong install page is the most expensive kind of wrong - it is read once, by
# somebody who has no way to tell whether the mistake is theirs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A path dependency takes its identity from the directory name, not from the package
# name in the manifest - so this is `repo` in the vault checkout and `loupe` in a
# plain clone. Read it rather than assuming, or this fails on one machine and not the
# other for a reason that has nothing to do with the guide.
pkg="$(basename "$here")"

mkdir -p "$work/Sources/Host"

cat > "$work/Package.swift" <<PACKAGE
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Host",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [.package(path: "$here")],
    targets: [
        .executableTarget(name: "Host", dependencies: [
            .product(name: "LoupeCore", package: "$pkg"),
            .product(name: "LoupeUI", package: "$pkg"),
            .product(name: "LoupeLinear", package: "$pkg"),
        ]),
    ])
PACKAGE

# Every call the guide asks a host to make, in the shape it asks for it. Kept as one
# file rather than extracted from the markdown: extraction would test the fences, and
# what matters is that the calls compile.
cat > "$work/Sources/Host/main.swift" <<'HOST'
import Foundation
import LoupeCore
import LoupeUI
import LoupeLinear

@MainActor
func install(window: PlatformWindow) {
    // "2. Start and attach, guarded"
    let app = AppInfo(
        name: "Host",
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        commitSHA: "abc1234",
        platform: "macOS",
        environment: "staging")
    Loupe.start(app: app)
    Loupe.attach(to: window)

    // "2b. If the host app has a design system, hand Loupe its tokens"
    Loupe.start(app: app, theme: LoupeTheme.Appearance(
        accent: .init(light: .init(hex: 0x4338CA), dark: .init(hex: 0xA5B4FC)),
        label: .headline,
        panelRadius: 28))

    // "3. Where bundles land" - the device transport
    Loupe.start(app: app, transport: QueuedTransport(
        wrapping: HTTPTransport(endpoint: URL(string: "http://127.0.0.1:3000/loupe/intake")!),
        directory: FileTransport.defaultDirectory(appName: app.name)))

    // The Linear delivery, and its two-line setup from the README.
    Loupe.start(app: app, transport: LinearDelivery(
        keeping: FileTransport(directory: FileTransport.defaultDirectory(appName: app.name))))
    LoupeLinear.enable(oauth: LinearOAuth(clientID: "public-id", redirectURI: "host://linear"))

    // "How the person opens it", and the teardown a host menu would call.
    Loupe.toggleAnnotating()
    Loupe.handleShake()
    Loupe.stop()
}

print("the install guide still compiles")
HOST

# The file above is a copy of what the guide asks for, and a copy can drift from the
# thing it claims to check - which would leave this passing while the page a stranger
# reads is wrong. So the copy is held to the page: every line below must appear in it
# verbatim.
echo "==> checking the guide still says what this script compiles"
missing=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! grep -qF "$line" "$here/docs/agent-install.md"; then
        echo "    NOT IN THE GUIDE: $line"
        missing=1
    fi
done <<'ANCHORS'
Loupe.start(app: app, theme: LoupeTheme.Appearance(
    label: .headline,
    panelRadius: 28))
Loupe.start(app: app, transport: QueuedTransport(
    wrapping: HTTPTransport(endpoint: URL(string: "http://<your machine>:3000/loupe/intake")!),
    directory: FileTransport.defaultDirectory(appName: app.name)))
ANCHORS

if [ "$missing" = 1 ]; then
    echo
    echo "    This script compiles a copy of the guide's snippets. A line it compiles"
    echo "    is no longer in docs/agent-install.md, so the two have drifted and the"
    echo "    page a new adopter reads is the one nobody is checking. Fix whichever"
    echo "    is wrong, and keep them the same."
    exit 1
fi
echo "    the guide and this script still agree"

echo "==> building what docs/agent-install.md asks a host to write"
( cd "$work" && swift build 2>&1 | sed 's/^/    /' )
echo "    the install guide still compiles"
