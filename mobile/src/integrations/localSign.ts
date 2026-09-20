import type { TranslationEvent } from './contracts.ts';
import type { SignPredictionEvent } from '../../modules/signloop-camera/events.ts';

/** Exact presentation vocabulary shared with BasicSignScore.presentationVocabulary. */
export const signText = {
  HELLO: 'Hello.', MY: 'My', NAME: 'Name', TODAY: 'Today', WE: 'We', SHOW: 'Show',
  PHONE: 'Phone', PLEASE: 'Please.', SORRY: 'Sorry.', THANKYOU: 'Thank you.', ILOVEYOU: 'I love you.',
} as const;

/** Delivery must be fresh; selecting a choice freezes its bounded review period. */
export const SIGN_REVIEW_MS = 10_000;

/** Fresh rolling rankings offer the same explicit review as completed gestures. */
export function candidateFromPrediction(event: SignPredictionEvent, active: boolean, captureId: number,
  now = Date.now()): TranslationEvent | null {
  if (!active || event.captureId !== captureId) return null;
  if (event.engine !== 'basic-temporal-v3' || typeof event.matched !== 'boolean'
    || !Number.isFinite(event.observedAtMS) || now - event.observedAtMS < -100
    || now - event.observedAtMS > 1000) return { type: 'clear-candidate' };
  if (event.phase === 'cleared') return { type: 'clear-candidate' };
  if (event.phase === 'preview' && event.label === null && Array.isArray(event.candidates) && event.candidates.length === 0) {
    return { type: 'sign-preview', text: '' };
  }
  if (!['preview', 'completed'].includes(event.phase) || !Number.isSafeInteger(event.attemptId) || event.attemptId! <= 0
    || !Array.isArray(event.candidates) || event.candidates.length < 1 || event.candidates.length > 3
    || event.candidates.some((choice, index, choices) => !choice || typeof choice.label !== 'string'
      || !Object.hasOwn(signText, choice.label) || !Number.isFinite(choice.distance) || choice.distance < 0
      || (index > 0 && choice.distance < choices[index - 1].distance))
    || new Set(event.candidates.map(choice => choice.label)).size !== event.candidates.length
    || event.label !== event.candidates[0].label) return { type: 'clear-candidate' };
  const options = event.candidates.map(({ label }) => ({ label, text: signText[label as keyof typeof signText] }));
  return { type: 'candidate', ...options[0], attemptId: event.attemptId!, options,
    observedAtMS: event.observedAtMS, selected: false,
    // Complete-segment scores have not been calibrated as probabilities.
    uncertain: true, expiresAtMS: event.observedAtMS + SIGN_REVIEW_MS };
}
