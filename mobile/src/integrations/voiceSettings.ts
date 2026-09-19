export type VoiceSettings = Readonly<{ url: string; token: string; enabled: boolean }>;
let settings: VoiceSettings = { url: '', token: '', enabled: false };
const listeners = new Set<() => void>();

/** Session-memory only. Never persist a provider key or put credentials in a URL. */
export const getVoiceSettings = () => settings;
export function subscribeVoiceSettings(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export function setVoiceSettings(next: VoiceSettings) {
  settings = Object.freeze({ ...next });
  listeners.forEach(listener => listener());
}
export function disableVoiceUploads() {
  if (settings.enabled) setVoiceSettings({ ...settings, enabled: false });
}

export function backendOrigin(value: string): string {
  let url: URL;
  try { url = new URL(value.trim()); } catch { throw new Error('Enter a valid backend URL.'); }
  if (url.username || url.password || url.search || url.hash || !['', '/'].includes(url.pathname)) {
    throw new Error('Use a backend origin without credentials, a path, or query parameters.');
  }
  const host = url.hostname.toLowerCase();
  const parts = host.split('.').map(Number);
  const ipv4 = /^\d+\.\d+\.\d+\.\d+$/.test(host) && parts.every(p => p >= 0 && p <= 255);
  const local = host === 'localhost' || host === '[::1]' || host.endsWith('.local')
    || (ipv4 && (parts[0] === 127 || parts[0] === 10
      || (parts[0] === 192 && parts[1] === 168)
      || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)));
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
    throw new Error('Use HTTPS, or local HTTP on a trusted development LAN.');
  }
  return url.origin;
}
