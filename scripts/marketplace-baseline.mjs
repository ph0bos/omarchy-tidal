// Run the Omarchy plugin marketplace's own submission checks against this tree.
//
// The marketplace validates a submission at an exact commit and posts the
// result on the submission issue. Finding out there is a slow loop: push, wait
// for a bot, read a comment, fix, push again -- and every push moves the SHA a
// maintainer would have to re-approve. Its rules are public MIT-licensed code,
// so this runs the real thing locally and in CI instead of approximating it.
//
// The rules are NOT vendored. CI downloads them at a pinned commit
// (scripts/marketplace-baseline.json) and passes the directory in, so what runs
// here is the marketplace's code rather than our reading of it, and an update
// to the pin is a reviewable change rather than a silent drift.
//
//   node scripts/marketplace-baseline.mjs <marketplace-scripts-dir> [repo-root]
//
// Exits non-zero when the baseline reports findings -- the outcome that blocks
// a listing. Capabilities are printed but never fail the build: this plugin
// installs packages and manages a user service on purpose, and the marketplace
// asks a human to accept that rather than treating it as a defect.

import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [rulesDir, repoRoot = "."] = process.argv.slice(2);

if (!rulesDir) {
  console.error("usage: marketplace-baseline.mjs <marketplace-scripts-dir> [repo-root]");
  process.exit(2);
}

const rules = (name) => import(pathToFileURL(path.join(rulesDir, name)).href);
const { buildSecurityBaseline } = await rules("security-baseline-analysis.mjs");
const { isSecurityScanPath, securityFileByteLimit } = await rules("security-baseline-scope.mjs");

// Mirror what the marketplace pulls out of a GitHub tree: the paths its scope
// rules select, plus anything executable, minus anything too big for it to
// read. Close enough that a clean run here means a clean run there; the one
// thing it cannot see is a file that is committed but absent locally, which is
// what CI checking out the repo takes care of.
function scannedFiles(root) {
  const files = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      if (name === ".git" || name === "node_modules") continue;
      const full = path.join(dir, name);
      const rel = path.relative(root, full);
      const stats = statSync(full);
      if (stats.isDirectory()) { walk(full); continue; }
      const executable = (stats.mode & 0o111) !== 0;
      if (!isSecurityScanPath(rel) && !executable) continue;
      if (stats.size > securityFileByteLimit) continue;
      let content;
      try {
        content = readFileSync(full, "utf8");
      } catch {
        continue;
      }
      files.push({ path: rel, content });
    }
  };
  walk(root);
  return files;
}

function repositoryIdentity(root) {
  // The analysis wants the repository the submission claims, so it can tell a
  // download from this repository apart from one off the internet.
  const manifest = JSON.parse(readFileSync(path.join(root, "manifest.json"), "utf8"));
  const url = String(manifest.repository || "");
  const match = url.match(/github\.com[/:]+([^/]+)\/([^/.]+)/i);
  if (!match) throw new Error(`manifest.repository is not a GitHub url: ${url}`);
  return { slug: `${match[1]}/${match[2]}`, url: `https://github.com/${match[1]}/${match[2]}` };
}

const root = path.resolve(repoRoot);
const { slug, url } = repositoryIdentity(root);
const files = scannedFiles(root);

const baseline = buildSecurityBaseline({
  repository: slug,
  repoUrl: url,
  // The analysis only records this; it does not resolve it. A working tree has
  // no commit of its own, and the zero sha keeps that honest.
  commitSha: "0".repeat(40),
  files,
});

// ---- listing prerequisites -------------------------------------------------
//
// The other half of what the marketplace checks: a README, a licence, and a
// root preview image, or the listing falls back to a generic card. These rules
// live in the marketplace's build-catalog.mjs, which needs a GitHub tree rather
// than a directory, so they are restated here -- the numbers are its numbers.

const previewByteLimit = 50 * 1024 * 1024;
const previewPixelLimit = 40_000_000;
const previewNames = ["preview.png", "preview.webp", "preview.jpg", "preview.jpeg", "preview.avif"];

function pngSize(file) {
  const header = readFileSync(file).subarray(0, 24);
  const isPng = header.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (!isPng || header.subarray(12, 16).toString("ascii") !== "IHDR") return null;
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}

function has(root, names) {
  return readdirSync(root).find((name) => names.includes(name.toLowerCase())) || "";
}

const listing = [];
const readme = has(root, ["readme.md", "readme", "readme.markdown", "readme.txt"]);
listing.push([Boolean(readme), `root README (${readme || "missing"})`]);

const licence = has(root, ["license", "license.md", "licence", "licence.md", "copying"]);
listing.push([Boolean(licence), `root licence (${licence || "missing"})`]);

const preview = readdirSync(root).find((name) => previewNames.includes(name.toLowerCase()));
if (!preview) {
  listing.push([false, "root preview image (the listing would use a fallback card)"]);
} else {
  const bytes = statSync(path.join(root, preview)).size;
  listing.push([bytes > 0 && bytes <= previewByteLimit,
    `${preview} is ${(bytes / 1024).toFixed(0)} KB (limit ${previewByteLimit / 1024 / 1024} MB)`]);
  const size = preview.toLowerCase().endsWith(".png") ? pngSize(path.join(root, preview)) : null;
  if (size) {
    listing.push([size.width * size.height <= previewPixelLimit,
      `${preview} is ${size.width}x${size.height} (limit ${previewPixelLimit / 1_000_000}M pixels)`]);
  }
}

let listingFailures = 0;
console.log("\nlisting prerequisites:");
for (const [ok, description] of listing) {
  console.log(`  ${ok ? "ok  " : "MISS"} ${description}`);
  if (!ok) listingFailures += 1;
}

const label = { "passed": "passed", "review-required": "review required", "needs-fixes": "needs fixes" };
console.log(`\nmarketplace baseline: ${label[baseline.outcome] || baseline.outcome}`);
console.log(`  scanned ${files.length} files against rules in ${rulesDir}`);

// Capabilities are keyed `id`; findings are keyed `ruleId`.
for (const capability of baseline.capabilities) {
  const where = (capability.evidence || [])
    .map((item) => `${item.path}:${item.line}`)
    .slice(0, 3)
    .join(", ");
  console.log(`  capability: ${capability.id} — ${capability.title}${where ? ` (${where})` : ""}`);
}

for (const finding of baseline.findings) {
  console.log(`::error::marketplace finding: ${finding.ruleId} — ${finding.title || ""}`);
  for (const item of finding.evidence || []) {
    console.log(`    ${item.path}:${item.line}  ${String(item.snippet || "").slice(0, 120)}`);
  }
}

if (!baseline.findings.length) {
  console.log("  no findings");
  if (baseline.capabilities.length) {
    console.log("  capabilities need a maintainer to accept them; that is not a defect.");
  }
}

if (baseline.findings.length || listingFailures) {
  console.log(`\n${baseline.findings.length} finding(s) and ${listingFailures} missing`
    + " prerequisite(s) would stand between this tree and a listing.");
  process.exit(1);
}
