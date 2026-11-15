// Prints raw, gzip and brotli sizes of what a first page load fetches.
import zlib from "node:zlib";
import { buildAssets } from "./server.mjs";

const sizes = (data) => [data.length, zlib.gzipSync(data, { level: 9 }).length,
  zlib.brotliCompressSync(data, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length];
const kb = (n) => (n / 1024).toFixed(1).padStart(7);

function table(title, rows) {
  console.log(`\n${title}\n${"file".padEnd(34)}    raw KiB   gzip KiB  brotli KiB`);
  const total = [0, 0, 0];
  for (const [name, data] of rows) {
    const [raw, gz, br] = sizes(data);
    total[0] += raw; total[1] += gz; total[2] += br;
    console.log(`${name.padEnd(34)} ${kb(raw)}    ${kb(gz)}    ${kb(br)}`);
  }
  console.log(`${"total".padEnd(34)} ${kb(total[0])}    ${kb(total[1])}    ${kb(total[2])}`);
  return total;
}

const assets = buildAssets();
const loaded = [...assets.files.keys()].filter((name) => /\.(js|css)$/.test(name)).sort();
const page = table("new page (index.html as served, every module and stylesheet)",
  [["index.html", Buffer.from(assets.html)], ...loaded.map((name) => [name, assets.files.get(name).data])]);
const ours = table("new page without vendor files", [["index.html", Buffer.from(assets.html)],
  ...loaded.filter((name) => !name.startsWith("vendor/")).map((name) => [name, assets.files.get(name).data])]);
console.log(`\npage code alone ${kb(ours[1])} KiB gzip`);
