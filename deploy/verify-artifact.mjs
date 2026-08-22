#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstat, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";

function fail(message) {
  throw new Error(message);
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) fail("arguments must use --name value pairs");
    values.set(key.slice(2), value);
  }
  for (const required of ["artifact", "manifest"]) {
    if (!values.has(required)) fail(`missing --${required}`);
  }
  return values;
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) fail(`${command} failed with exit ${result.status}: ${result.stderr.trim()}`);
  return result.stdout;
}

async function collectExtracted(root) {
  const files = new Map();
  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = join(directory, entry.name);
      const metadata = await lstat(absolute);
      const path = relative(root, absolute).split(sep).join("/");
      if (metadata.isSymbolicLink()) fail(`extracted symlink is forbidden: ${path}`);
      if (metadata.isDirectory()) {
        await visit(absolute);
      } else if (metadata.isFile()) {
        if ((metadata.mode & 0o111) !== 0) fail(`unexpected executable file: ${path}`);
        const content = await readFile(absolute);
        files.set(path, { size: content.byteLength, sha256: sha256(content) });
      } else {
        fail(`extracted special file is forbidden: ${path}`);
      }
    }
  }
  await visit(root);
  return files;
}

const args = parseArguments(process.argv.slice(2));
const artifactPath = resolve(args.get("artifact"));
const manifestPath = resolve(args.get("manifest"));
if (!(await stat(artifactPath)).isFile() || !(await stat(manifestPath)).isFile()) fail("artifact inputs must be files");

const artifactContent = await readFile(artifactPath);
const manifestContent = await readFile(manifestPath);
const artifactDigest = sha256(artifactContent);
const manifestDigest = sha256(manifestContent);
if (args.get("artifact-sha256") && args.get("artifact-sha256") !== artifactDigest) fail("artifact checksum argument mismatch");
if (args.get("manifest-sha256") && args.get("manifest-sha256") !== manifestDigest) fail("manifest checksum argument mismatch");

const manifest = JSON.parse(manifestContent.toString("utf8"));
if (manifest.schemaVersion !== 1) fail("unsupported artifact manifest schema");
if (manifest.artifact?.sha256 !== artifactDigest || manifest.artifact?.size !== artifactContent.byteLength) {
  fail("artifact content does not match its manifest");
}

const names = run("tar", ["--list", "--gzip", "--file", artifactPath]).split("\n").filter(Boolean);
for (const rawName of names) {
  const name = rawName.replace(/^\.\//, "");
  if (name.startsWith("/") || name.split("/").includes("..") || /[\u0000-\u001f\u007f]/u.test(name)) {
    fail(`unsafe archive path: ${rawName}`);
  }
}

const verbose = run("tar", ["--list", "--verbose", "--numeric-owner", "--gzip", "--file", artifactPath]);
for (const line of verbose.split("\n").filter(Boolean)) {
  if (!"-d".includes(line[0])) fail("archive contains a link, device, socket, or FIFO");
  const mode = line.slice(0, 10);
  if (line[0] === "-" && mode !== "-rw-r--r--") fail("archive file mode is not normalized");
  if (line[0] === "d" && mode !== "drwxr-xr-x") fail("archive directory mode is not normalized");
  if (!/\s0\/0\s/.test(line)) fail("archive ownership is not normalized");
}

const temporary = await mkdtemp(join(tmpdir(), "platform-artifact-verify-"));
try {
  run("tar", [
    "--extract",
    "--gzip",
    "--file", artifactPath,
    "--directory", temporary,
    "--no-same-owner",
    "--no-same-permissions",
    "--delay-directory-restore",
    "--keep-old-files",
  ]);

  const extracted = await collectExtracted(temporary);
  const expected = new Map();
  for (const entry of manifest.files ?? []) {
    if (
      !entry.path ||
      expected.has(entry.path) ||
      entry.path.startsWith("/") ||
      entry.path.split("/").includes("..") ||
      /[\u0000-\u001f\u007f]/u.test(entry.path)
    ) {
      fail("invalid or duplicate manifest path");
    }
    expected.set(entry.path, { size: entry.size, sha256: entry.sha256, classification: entry.classification });
  }
  if (extracted.size !== expected.size) fail("artifact and manifest file counts differ");
  for (const [path, metadata] of expected) {
    const actual = extracted.get(path);
    if (!actual || actual.size !== metadata.size || actual.sha256 !== metadata.sha256) {
      fail(`artifact file does not match manifest: ${path}`);
    }
  }

  const required = ["index.html", "__spa-fallback.html", "rss.xml", "sitemap.xml", "robots.txt"];
  for (const path of required) if (!expected.has(path)) fail(`required file is missing: ${path}`);
  if (![...expected.keys()].some((path) => path.endsWith(".html"))) fail("HTML routes are missing");
  if (![...expected.keys()].some((path) => path.endsWith(".data"))) fail("route data files are missing");
  if (expected.get("rss.xml")?.classification !== "rss") fail("RSS classification mismatch");
  if (expected.get("sitemap.xml")?.classification !== "sitemap") fail("sitemap classification mismatch");
  if (expected.get("robots.txt")?.classification !== "robots") fail("robots classification mismatch");

  process.stdout.write(`${JSON.stringify({
    verified: true,
    artifactSha256: artifactDigest,
    manifestSha256: manifestDigest,
    fileCount: expected.size,
  })}\n`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}
