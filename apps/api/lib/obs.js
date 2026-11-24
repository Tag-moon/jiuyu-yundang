import { env } from './env.js';

export function imageUrl(site) {
  if (!site?.image) return '';
  const base = String(env.OBS_IMAGE_BASE_URL || '').replace(/\/$/, '');
  return base ? `${base}/${site.image}` : `/images/${site.image}`;
}

export function obsInfo() {
  return {
    configured: Boolean(env.OBS_IMAGE_BASE_URL),
    baseUrl: env.OBS_IMAGE_BASE_URL || '/images (local fallback)'
  };
}
