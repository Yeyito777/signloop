import type { TranslationEvent } from './contracts.ts';

export type LocalSignEvent = { captureId: number; label: string | null; observedAtMS: number };
export const presentationSigns: Record<string, string> = {
  HELLO: 'Hello', MY: 'My', NAME: 'Name', TODAY: 'Today', WE: 'We', SHOW: 'Show',
  PHONE: 'Phone', PLEASE: 'Please', SORRY: 'Sorry', THANKYOU: 'Thank you', ILOVEYOU: 'I love you.',
};
export const nameLetters = ['A', 'U', 'R', 'E', 'L', 'I', 'O'];
export function freshObservation(observedAtMS: number, now = Date.now()) {
  return Number.isFinite(observedAtMS) && now-observedAtMS >= -100 && now-observedAtMS <= 1000;
}

/** Never promote a canned gesture or a stale event into automatically spoken words. */
export function candidateFromSign(event: LocalSignEvent, active: boolean, captureId: number, now = Date.now()): TranslationEvent | null {
  if (!active || event.captureId !== captureId) return null;
  if (event.label === null) return { type: 'clear-candidate' };
  const text = Object.hasOwn(presentationSigns, event.label) ? presentationSigns[event.label]
    : event.label === 'I_LOVE_YOU' ? 'I love you.' : null; // old native clients only
  if (!text || !freshObservation(event.observedAtMS, now)) return { type: 'clear-candidate' };
  return { type: 'candidate', label: event.label, text, expiresAtMS: event.observedAtMS + 1000 };
}
