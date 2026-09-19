import type { TranslationEvent } from './contracts.ts';

export type LocalSignEvent = { captureId: number; label: string | null; observedAtMS: number };

/** Never promote a canned gesture or a stale event into automatically spoken words. */
export function candidateFromSign(event: LocalSignEvent, active: boolean, captureId: number, now = Date.now()): TranslationEvent | null {
  if (!active || event.captureId !== captureId) return null;
  if (event.label === null) return { type: 'clear-candidate' };
  if (event.label !== 'I_LOVE_YOU' || !Number.isFinite(event.observedAtMS)
    || now - event.observedAtMS < -100 || now - event.observedAtMS > 1000) return { type: 'clear-candidate' };
  return { type: 'candidate', label: event.label, text: 'I love you.', expiresAtMS: event.observedAtMS + 1000 };
}
