// Regenerates every Zimmer icon from the master artwork in this directory.
//
//   cd docs && npm run icons
//
// The script lives under docs/ because docs/ is the only npm workspace in the
// repo — sharp is already a dependency here and CI installs it. It writes to
// two places: docs/public/ (the documentation site's favicons) and
// ../public/ (the Rails app's favicons, PWA icons and apple-touch icon), so a
// single run keeps the browser tab, the installed PWA and the docs site on the
// same artwork.
//
// Two derivations of the master exist on purpose:
//
//   full     the whole 1254x1254 render, edge to edge. Used wherever the icon
//            is displayed large enough for the mascot, the tablet and the gold
//            ring to all read: PWA icons, apple-touch-icon.
//
//   portrait a 700x700 crop centred on the face. A naive downscale of the full
//            render turns to mud at 16px — the mascot becomes a brown smudge
//            inside a navy square. The crop throws away the ring and the
//            tablet so the eyes, glasses and snout survive the resample. Used
//            for favicon.ico and the 16/32px <link rel="icon"> PNGs.
//
// The maskable variants pad the full render down to 80% of the canvas so the
// artwork survives Android's circle/squircle crop, which only guarantees the
// centre 80% ("safe zone"). Declaring the full-bleed render maskable would clip
// the mascot's ears and the gold ring.

import { Buffer } from "node:buffer";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SOURCE = path.join(HERE, "zimmer-icon-source.jpg");
const DOCS_PUBLIC = path.join(HERE, "..", "public");
const APP_PUBLIC = path.join(HERE, "..", "..", "public");
const APP_ICONS = path.join(APP_PUBLIC, "icons");

// Centred on the mascot's face in the 1254x1254 master.
const PORTRAIT = { left: 277, top: 120, width: 700, height: 700 };

// Sampled from the master: the outer navy at the corners and the lighter navy
// the radial background lifts to behind the mascot.
const NAVY_EDGE = "#000e2b";
const NAVY_CORE = "#04204f";

// Fraction of a maskable canvas the artwork is allowed to occupy.
const MASKABLE_SCALE = 0.8;

const full = () => sharp(SOURCE);
const portrait = () => sharp(SOURCE).extract(PORTRAIT);

// Small renders lose local contrast to the resampler; a light unsharp mask puts
// the glasses and the snout back. Larger renders are left alone.
//
// The large renders are quantised to a 256-colour palette, which is a quarter
// of the truecolour file size with no visible difference at any size the icons
// are actually displayed at — including the navy background gradient, which is
// where banding would show first. The .ico entries stay truecolour: the format
// advertises 32bpp per entry and there is nothing to gain on a 48px image.
async function render(input, size, { sharpen = size <= 64, palette = size >= 96 } = {}) {
  let pipeline = input.resize(size, size, { kernel: "lanczos3", fit: "fill" });
  if (sharpen) pipeline = pipeline.sharpen({ sigma: 0.6, m1: 0.4, m2: 1.4 });
  return pipeline.png({ compressionLevel: 9, effort: 10, palette }).toBuffer();
}

// The artwork's own radial navy, extended past the edge of the render so the
// padding does not read as a flat rectangle behind a gradient square.
function maskableBackground(size) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">
  <defs>
    <radialGradient id="bg" cx="50%" cy="46%" r="72%">
      <stop offset="0%" stop-color="${NAVY_CORE}"/>
      <stop offset="100%" stop-color="${NAVY_EDGE}"/>
    </radialGradient>
  </defs>
  <rect width="${size}" height="${size}" fill="url(#bg)"/>
</svg>`;
  return Buffer.from(svg);
}

// The scaled artwork carries its own radial background, which cannot be matched
// exactly by the generated one — dropped in as a hard square it leaves a faint
// seam. Feathering the outermost few percent of the artwork to transparent
// dissolves that edge; nothing but flat navy lives out there in the master.
function featherMask(size) {
  const feather = Math.max(2, Math.round(size * 0.035));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">
  <defs><filter id="f"><feGaussianBlur stdDeviation="${feather / 2}"/></filter></defs>
  <rect x="${feather}" y="${feather}" width="${size - feather * 2}" height="${size - feather * 2}" fill="#fff" filter="url(#f)"/>
</svg>`;
  return Buffer.from(svg);
}

async function maskable(size) {
  const inner = Math.round(size * MASKABLE_SCALE);
  const art = await sharp(await render(full(), inner, { sharpen: false, palette: false }))
    .composite([ { input: featherMask(inner), blend: "dest-in" } ])
    .png()
    .toBuffer();
  const offset = Math.round((size - inner) / 2);
  return sharp(maskableBackground(size))
    .composite([ { input: art, left: offset, top: offset } ])
    .png({ compressionLevel: 9, effort: 10, palette: true })
    .toBuffer();
}

// A .ico is a directory of images; every modern browser and both desktop OSes
// read PNG-compressed entries, which keeps the file a fraction of the size of
// the equivalent BMP entries.
function ico(pngs) {
  const HEADER = 6;
  const ENTRY = 16;
  const header = Buffer.alloc(HEADER);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // 1 = icon
  header.writeUInt16LE(pngs.length, 4);

  let offset = HEADER + ENTRY * pngs.length;
  const entries = pngs.map(({ size, data }) => {
    const entry = Buffer.alloc(ENTRY);
    entry.writeUInt8(size === 256 ? 0 : size, 0); // 0 means 256
    entry.writeUInt8(size === 256 ? 0 : size, 1);
    entry.writeUInt8(0, 2); // palette size, 0 for truecolour
    entry.writeUInt8(0, 3); // reserved
    entry.writeUInt16LE(1, 4); // colour planes
    entry.writeUInt16LE(32, 6); // bits per pixel
    entry.writeUInt32LE(data.length, 8);
    entry.writeUInt32LE(offset, 12);
    offset += data.length;
    return entry;
  });

  return Buffer.concat([ header, ...entries, ...pngs.map((p) => p.data) ]);
}

async function main() {
  await mkdir(APP_ICONS, { recursive: true });
  await mkdir(DOCS_PUBLIC, { recursive: true });

  const written = [];
  const write = async (file, data) => {
    await writeFile(file, data);
    written.push(`${path.relative(path.join(HERE, "..", ".."), file)}  ${data.length} bytes`);
  };

  const favicon16 = await render(portrait(), 16);
  const favicon32 = await render(portrait(), 32);
  const favicon48 = await render(portrait(), 48);
  const faviconIco = ico([
    { size: 16, data: favicon16 },
    { size: 32, data: favicon32 },
    { size: 48, data: favicon48 },
  ]);

  // Rails app.
  await write(path.join(APP_PUBLIC, "favicon.ico"), faviconIco);
  await write(path.join(APP_ICONS, "favicon-16x16.png"), favicon16);
  await write(path.join(APP_ICONS, "favicon-32x32.png"), favicon32);
  await write(path.join(APP_ICONS, "apple-touch-icon.png"), await render(full(), 180));
  await write(path.join(APP_ICONS, "icon-192x192.png"), await render(full(), 192));
  await write(path.join(APP_ICONS, "icon-512x512.png"), await render(full(), 512));
  await write(path.join(APP_ICONS, "icon-maskable-192x192.png"), await maskable(192));
  await write(path.join(APP_ICONS, "icon-maskable-512x512.png"), await maskable(512));

  // Documentation site.
  await write(path.join(DOCS_PUBLIC, "favicon.ico"), faviconIco);
  await write(path.join(DOCS_PUBLIC, "favicon-16x16.png"), favicon16);
  await write(path.join(DOCS_PUBLIC, "favicon-32x32.png"), favicon32);
  await write(path.join(DOCS_PUBLIC, "apple-touch-icon.png"), await render(full(), 180));

  console.log(written.join("\n"));
}

await main();
