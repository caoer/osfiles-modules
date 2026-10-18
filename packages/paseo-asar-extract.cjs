// Extract an Electron asar archive the way `asar extract` does, except that an
// entry marked unpacked but absent from <archive>.unpacked is skipped instead
// of aborting. Paseo's release strips such entries (the Claude Agent SDK's
// bundled `claude` binaries); stock `asar extract` dies on the first one.
// Usage: NODE_PATH=<asar>/lib/node_modules node paseo-asar-extract.cjs <archive> <dest>
const disk = require("@electron/asar/lib/disk");
const fs = require("fs");
const path = require("path");

const [archive, dest] = process.argv.slice(2);
const filesystem = disk.readFilesystemSync(archive);
const skipped = [];
fs.mkdirSync(dest, { recursive: true });

for (const full of filesystem.listFiles()) {
  const name = full.slice(1);
  const out = path.join(dest, name);
  const file = filesystem.getFile(name, false);
  if (file.files) {
    fs.mkdirSync(out, { recursive: true });
  } else if (file.link) {
    fs.rmSync(out, { force: true });
    fs.symlinkSync(path.relative(path.dirname(out), path.join(dest, file.link)), out);
  } else if (file.unpacked && !fs.existsSync(path.join(`${archive}.unpacked`, name))) {
    skipped.push(name);
  } else {
    fs.writeFileSync(out, disk.readFileSync(filesystem, name, file));
    if (file.executable) fs.chmodSync(out, 0o755);
  }
}
process.stderr.write(`paseo-asar-extract: ${skipped.length} unpacked entries absent from the release, skipped\n`);
