// Resize + re-encode photos in the browser before upload.
// Re-encoding through a canvas also strips EXIF metadata (including GPS location).

import { supabase } from '../supabase.js';

async function decode(file) {
  if ('createImageBitmap' in window) {
    try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch { /* fall through */ }
  }
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.decoding = 'async';
    img.src = url;
    await img.decode();
    return img;
  } finally {
    URL.revokeObjectURL(url);
  }
}

function toBlob(canvas, type, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

/**
 * @param {File} file
 * @param {{ maxSize?: number, square?: boolean, quality?: number }} opts
 * @returns {Promise<Blob>} image/webp, or image/jpeg where WebP encoding is unsupported
 */
export async function compressImage(file, { maxSize = 1600, square = false, quality = 0.8 } = {}) {
  const src = await decode(file);
  const sw = src.width, sh = src.height;
  let sx = 0, sy = 0, cw = sw, ch = sh;
  if (square) {
    const side = Math.min(sw, sh);
    sx = (sw - side) / 2; sy = (sh - side) / 2; cw = ch = side;
  }
  const scale = Math.min(1, maxSize / Math.max(cw, ch));
  const w = Math.max(1, Math.round(cw * scale));
  const hgt = Math.max(1, Math.round(ch * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = hgt;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(src, sx, sy, cw, ch, 0, 0, w, hgt);
  if (src.close) src.close();

  let blob = await toBlob(canvas, 'image/webp', quality);
  if (!blob || blob.type !== 'image/webp') blob = await toBlob(canvas, 'image/jpeg', quality);
  if (!blob) throw new Error('Could not process that photo');
  return blob;
}

/** Uploads to {bucket}/{uid}/{random}.{ext} and returns the storage path. */
export async function uploadPhoto(bucket, uid, blob) {
  const ext = blob.type === 'image/webp' ? 'webp' : 'jpg';
  const path = `${uid}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from(bucket).upload(path, blob, {
    contentType: blob.type,
    cacheControl: '31536000',
    upsert: false,
  });
  if (error) throw error;
  return path;
}

// Signed URLs (buckets are private; RLS decides who may read).
const cache = new Map(); // key -> { url, expires }

export async function photoUrls(bucket, paths) {
  const now = Date.now();
  const need = [...new Set(paths.filter(Boolean))].filter((p) => {
    const c = cache.get(`${bucket}/${p}`);
    return !c || c.expires < now;
  });
  if (need.length) {
    const { data, error } = await supabase.storage.from(bucket).createSignedUrls(need, 3600);
    if (!error && data) {
      for (const row of data) {
        if (row.signedUrl) cache.set(`${bucket}/${row.path}`, { url: row.signedUrl, expires: now + 50 * 60 * 1000 });
      }
    }
  }
  const out = {};
  for (const p of paths) if (p && cache.has(`${bucket}/${p}`)) out[p] = cache.get(`${bucket}/${p}`).url;
  return out;
}

export async function photoUrl(bucket, path) {
  if (!path) return null;
  return (await photoUrls(bucket, [path]))[path] || null;
}
