#!/usr/bin/env node
'use strict';

// Download a public MEGA file through MEGA's share API rather than HTTP GET.
// The link is read from the environment and is never printed to the log.
const fs = require('node:fs/promises');
const path = require('node:path');
const { File } = require('megajs');

class SafeDownloadError extends Error {}

async function main() {
  const url = process.env.KIRBY_ROM_URL;
  const destination = process.env.KIRBY_ROM_OUTPUT;
  if (!url || !destination) {
    throw new SafeDownloadError('KIRBY_ROM_URL and KIRBY_ROM_OUTPUT must be set.');
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw new SafeDownloadError('KIRBY_ROM_URL is not a valid URL.');
  }
  if (parsed.protocol !== 'https:' || !/(^|\.)mega\.nz$|(^|\.)mega\.co\.nz$/i.test(parsed.hostname)) {
    throw new SafeDownloadError('KIRBY_ROM_URL must be a shared HTTPS MEGA file link.');
  }
  if (!/\/file\//i.test(parsed.pathname) && !parsed.hash.startsWith('#!') && !parsed.hash.startsWith('#F!')) {
    throw new SafeDownloadError('Unsupported MEGA share URL format. Use MEGA’s Copy link for the ROM file.');
  }

  const shared = File.fromURL(url);
  await shared.loadAttributes();
  if (shared.directory || !Number.isSafeInteger(Number(shared.size))) {
    throw new SafeDownloadError('The MEGA link did not resolve to a single file.');
  }
  const advertisedSize = Number(shared.size);
  if (advertisedSize < 32768 || advertisedSize > 16 * 1024 * 1024) {
    throw new SafeDownloadError('MEGA shared file size is outside the supported SNES ROM range: ' + advertisedSize + ' bytes.');
  }

  const data = await shared.downloadBuffer();
  if (!Buffer.isBuffer(data) || data.length !== advertisedSize) {
    throw new SafeDownloadError('MEGA download size does not match the file metadata.');
  }
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.writeFile(destination, data, { flag: 'wx' });
  console.log('MEGA file downloaded successfully (' + data.length + ' bytes).');
}

main().catch((error) => {
  // MEGA client/network errors may contain the original share URL and its
  // decryption key. Only print messages created by this script.
  if (error instanceof SafeDownloadError) {
    console.error('MEGA ROM download failed: ' + error.message);
  } else {
    console.error('MEGA ROM download failed while resolving or decrypting the share link. Check that the full, accessible file link was copied.');
  }
  process.exitCode = 1;
});
