#!/usr/bin/env node
import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail("arguments must be supplied as --name value pairs");
    }
    values.set(key.slice(2), value);
  }
  for (const required of ["input", "release-manifest", "source-commit-time", "output-dir"]) {
    if (!values.has(required)) fail(`missing --${required}`);
  }
  return values;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function classify(path) {
  if (path === "rss.xml") return "rss";
  if (path === "sitemap.xml") return "sitemap";
  if (path === "robots.txt") return "robots";
  if (path.endsWith(".html")) return "html";
  if (path.endsWith(".data")) return "route-data";
  if (/\.(?:css|js|mjs|map)$/i.test(path)) return "script-or-style";
  if (/\.(?:png|jpe?g|gif|webp|avif|svg|ico)$/i.test(path)) return "image";
  if (/\.(?:woff2?|ttf|otf)$/i.test(path)) return "font";
  if (path.endsWith(".pdf")) return "document";
  if (path.endsWith(".xml")) return "xml";
  return "static-other";
}

async function collectFiles(root) {
  const files = [];

  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name, "en"));
    for (const entry of entries) {
      const absolute = join(directory, entry.name);
      const metadata = await lstat(absolute);
      const path = relative(root, absolute).split(sep).join("/");
      if (
        !path ||
        path.startsWith("/") ||
        path.split("/").includes("..") ||
        /[\u0000-\u001f\u007f]/u.test(path)
      ) {
        fail(`unsafe static path: ${path}`);
      }
      if (metadata.isSymbolicLink()) fail(`symlinks are not permitted: ${path}`);
      if (metadata.isDirectory()) {
        await visit(absolute);
      } else if (metadata.isFile()) {
        if ((metadata.mode & 0o111) !== 0) fail(`executable static file is not permitted: ${path}`);
        const content = await readFile(absolute);
        files.push({
          path,
          size: content.byteLength,
          sha256: sha256(content),
          classification: classify(path),
        });
      } else {
        fail(`device, socket, or FIFO is not permitted: ${path}`);
      }
    }
  }

  await visit(root);
  files.sort((left, right) => left.path.localeCompare(right.path, "en"));
  return files;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: options.encoding ?? "utf8",
    maxBuffer: 512 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    fail(`${command} failed with exit ${result.status}: ${(result.stderr ?? "").toString().trim()}`);
  }
  return result;
}

const argumentsMap = parseArguments(process.argv.slice(2));
const input = resolve(argumentsMap.get("input"));
const releaseManifestPath = resolve(argumentsMap.get("release-manifest"));
const outputDirectory = resolve(argumentsMap.get("output-dir"));
const sourceCommitTime = Number(argumentsMap.get("source-commit-time"));

if (!Number.isSafeInteger(sourceCommitTime) || sourceCommitTime <= 0) {
  fail("source commit time must be a positive Unix timestamp");
}
if (!(await stat(input)).isDirectory()) fail("artifact input must be a directory");

const releaseDefinition = JSON.parse(await readFile(releaseManifestPath, "utf8"));
if (releaseDefinition.schemaVersion !== 1) fail("unsupported release manifest schema");
if (releaseDefinition.outputDirectory !== "build/client") fail("release output directory is not approved");
if (releaseDefinition.runtimeEnvironmentVariables?.length !== 0) fail("runtime environment variables are not permitted");

const files = await collectFiles(input);
const paths = new Set(files.map((entry) => entry.path));
for (const required of releaseDefinition.expectedStaticInventory.requiredFiles) {
  if (!paths.has(required)) fail(`required static file is missing: ${required}`);
}
if (!files.some((entry) => entry.classification === "html")) fail("no HTML routes were produced");
if (!files.some((entry) => entry.classification === "route-data")) fail("no route data files were produced");

await mkdir(outputDirectory, { recursive: true, mode: 0o700 });
const commit = releaseDefinition.release.commit;
const artifactName = `${releaseDefinition.release.id}-${commit}.tar.gz`;
const manifestName = `${releaseDefinition.release.id}-${commit}.manifest.json`;
const artifactPath = join(outputDirectory, artifactName);
const manifestPath = join(outputDirectory, manifestName);
const temporary = await mkdtemp(join(tmpdir(), "platform-static-package-"));
const tarPath = join(temporary, "artifact.tar");

try {
  run("tar", [
    "--create",
    "--file", tarPath,
    "--directory", input,
    "--sort=name",
    "--format=posix",
    "--pax-option=delete=atime,delete=ctime",
    `--mtime=@${sourceCommitTime}`,
    "--owner=0",
    "--group=0",
    "--numeric-owner",
    "--mode=u+rwX,go+rX,go-w",
    ".",
  ]);

  const compressed = run("gzip", ["-n", "-9", "-c", tarPath], { encoding: null }).stdout;
  await writeFile(artifactPath, compressed, { mode: 0o600 });
  await chmod(artifactPath, 0o600);

  const artifactDigest = sha256(compressed);
  const manifest = {
    schemaVersion: 1,
    release: releaseDefinition.release,
    toolchain: releaseDefinition.toolchain,
    commands: releaseDefinition.commands,
    outputDirectory: releaseDefinition.outputDirectory,
    runtimeEnvironmentVariables: [],
    sourceCommitTime,
    packager: {
      name: "platform-static-packager",
      version: 1,
      node: process.version.slice(1),
    },
    artifact: {
      fileName: artifactName,
      size: compressed.byteLength,
      sha256: artifactDigest,
    },
    files,
  };
  const manifestContent = `${JSON.stringify(manifest, null, 2)}\n`;
  await writeFile(manifestPath, manifestContent, { mode: 0o600 });
  await chmod(manifestPath, 0o600);

  const manifestDigest = sha256(Buffer.from(manifestContent));
  const artifactChecksumPath = `${artifactPath}.sha256`;
  const manifestChecksumPath = `${manifestPath}.sha256`;
  await writeFile(artifactChecksumPath, `${artifactDigest}  ${basename(artifactPath)}\n`, { mode: 0o600 });
  await writeFile(manifestChecksumPath, `${manifestDigest}  ${basename(manifestPath)}\n`, { mode: 0o600 });
  await chmod(artifactChecksumPath, 0o600);
  await chmod(manifestChecksumPath, 0o600);

  process.stdout.write(`${JSON.stringify({
    artifactPath,
    artifactSha256: artifactDigest,
    artifactSize: compressed.byteLength,
    manifestPath,
    manifestSha256: manifestDigest,
    fileCount: files.length,
  })}\n`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}
