#!/usr/bin/env node
//
// A place for bundles to land, so "give it somewhere to send to" is one command
// instead of a snippet somebody has to wire into their own server first.
//
//   npx loupe-intake                 # http://127.0.0.1:7423/loupe/intake
//   npx loupe-intake --port 8080 --dir ./notes
//   npx loupe-intake --host 0.0.0.0  # so an iPad on the same network can reach it
//
// It writes the same shape `FileTransport` writes on disk, so anything that can read
// one can read the other:
//
//   .loupe/<sessionID>/bundle.json
//   .loupe/<sessionID>/<annotation id>.png
//   .loupe/<sessionID>/<annotation id>-context.png
//
// No dependencies, one file, and deliberately not a framework. If you need auth, a
// queue, or delivery into a tracker, this is the wrong thing to grow - put it behind
// your own service, or use LoupeLinear on Apple.
import { createServer } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

function flag(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const port = Number(flag("port", 7423));
const host = flag("host", "127.0.0.1");
const root = resolve(flag("dir", ".loupe"));
const route = flag("route", "/loupe/intake");

// Loupe is a dev and staging tool. A receiver that writes whatever it is posted, to
// disk, under a name it was given, has no business anywhere near production - and
// refusing loudly is better than a note in a readme nobody reads.
if (process.env.NODE_ENV === "production") {
  console.error("loupe-intake refuses to run with NODE_ENV=production.");
  process.exit(1);
}

/** A session id names a folder, so it may not contain a path. */
function safeName(value, fallback) {
  const name = String(value ?? "").trim();
  return /^[A-Za-z0-9._-]{1,128}$/.test(name) && name !== "." && name !== ".."
    ? name
    : fallback;
}

async function receive(bundle) {
  const session = safeName(bundle.sessionID, `unnamed-${Date.now()}`);
  const folder = join(root, session);
  await mkdir(folder, { recursive: true });

  let images = 0;
  for (const annotation of bundle.annotations ?? []) {
    const id = safeName(annotation.id, `annotation-${images}`);
    for (const [field, suffix] of [["screenshotPNG", ""], ["contextScreenshotPNG", "-context"]]) {
      const data = annotation[field];
      if (!data) continue;
      // Beside the JSON rather than inside it, so the JSON stays readable and an
      // agent can open the pictures directly.
      await writeFile(join(folder, `${id}${suffix}.png`), Buffer.from(data, "base64"));
      delete annotation[field];
      images += 1;
    }
  }

  await writeFile(join(folder, "bundle.json"), JSON.stringify(bundle, null, 2));
  return { folder, notes: (bundle.annotations ?? []).length, images };
}

const server = createServer((request, response) => {
  // The page is on one origin and this is on another, so without these the browser
  // never sends the body and the failure looks like the server being down.
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Headers", "content-type, authorization");
  response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");

  if (request.method === "OPTIONS") return response.writeHead(204).end();
  if (request.method !== "POST" || !request.url?.startsWith(route)) {
    return response.writeHead(404).end();
  }

  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", async () => {
    try {
      const bundle = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const { folder, notes, images } = await receive(bundle);
      console.log(`  ${notes} note(s), ${images} image(s) -> ${folder}`);
      response.writeHead(204).end();
    } catch (error) {
      // Said out loud, both ways. A bundle that failed to land while the sender was
      // told 204 is the one failure this whole project keeps designing out.
      console.error(`  refused: ${error.message}`);
      response.writeHead(400, { "content-type": "application/json" })
        .end(JSON.stringify({ error: String(error.message) }));
    }
  });
});

server.listen(port, host, () => {
  console.log(`loupe-intake  http://${host}:${port}${route}`);
  console.log(`  writing to  ${root}`);
  if (host !== "127.0.0.1" && host !== "localhost") {
    console.log(`  reachable from other machines on this network - it has no auth,`);
    console.log(`  so use it on a network you trust and stop it when you are done.`);
  }
  console.log(`  add ${flag("dir", ".loupe")}/ to .gitignore - bundles are notes, not source.`);
});
