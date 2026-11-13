// Verify the saved reference snapshot only. Does not execute downloaded code.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const root = __dirname;
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
let total = 0;
let failed = 0;
for (const entry of manifest.files) {
  const target = path.resolve(root, entry.localPath);
  const relative = path.relative(root, target);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`Path outside snapshot: ${entry.localPath}`);
  }
  // Reject symlinks in every path component, including intermediate directories.
  let current = root;
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    if (fs.lstatSync(current).isSymbolicLink()) {
      throw new Error(`Symlink in snapshot: ${entry.localPath}`);
    }
  }
  const bytes = fs.readFileSync(target);
  const actual = crypto.createHash('sha1')
    .update(Buffer.from(`blob ${bytes.length}\0`))
    .update(bytes)
    .digest('hex');
  total += bytes.length;
  if (actual !== entry.upstreamBlobSHA1) {
    failed++;
    console.error(`MISMATCH ${entry.localPath}`);
  }
}
console.log(JSON.stringify({ commit: manifest.commit, files: manifest.files.length, bytes: total, failed }, null, 2));
process.exitCode = failed ? 1 : 0;
