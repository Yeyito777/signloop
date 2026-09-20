import type { SignObservation, TranslationEvent } from './contracts.ts';
import type { SignPredictionEvent } from '../../modules/signloop-camera/events.ts';
import { isEmotion } from '../../../goose/src/emotion.ts';

export const nameLetters = ['A', 'U', 'R', 'E', 'L', 'I', 'O'];
export function freshObservation(observedAtMS: number, now = Date.now()) {
  return Number.isFinite(observedAtMS) && now-observedAtMS >= -100 && now-observedAtMS <= 1000;
}

/** Exact presentation vocabulary shared with BasicSignScore.presentationVocabulary. */
export const signText = {
  HELLO: 'Hello.', MY: 'My', NAME: 'Name', TODAY: 'Today', WE: 'We', SHOW: 'Show',
  PHONE: 'Phone', PLEASE: 'Please.', SORRY: 'Sorry.', THANKYOU: 'Thank you.', ILOVEYOU: 'I love you.',
} as const;
export type SignLabel = keyof typeof signText;

export const SIGN_FRESH_MS = 1000;

export function isFreshSign(observation: SignObservation, now = Date.now()): boolean {
  return Number.isSafeInteger(observation.attemptId) && observation.attemptId > 0
    && Number.isFinite(observation.observedAtMS)
    && now - observation.observedAtMS >= -100 && now - observation.observedAtMS < SIGN_FRESH_MS
    && !!observation.text.trim() && observation.text.length <= 500;
}

/** Show one rolling guess; speak the best complete-gesture match automatically. */
export function translationFromPrediction(event: SignPredictionEvent, active: boolean, captureId: number,
  now = Date.now()): TranslationEvent | null {
  if (!active || event.captureId !== captureId) return null;
  if (event.engine !== 'basic-temporal-v3' || typeof event.matched !== 'boolean'
    || !Number.isFinite(event.observedAtMS) || now - event.observedAtMS < -100
    || now - event.observedAtMS >= SIGN_FRESH_MS) return { type: 'clear-preview' };
  if (event.phase === 'cleared') return { type: 'clear-preview' };
  if (event.phase === 'preview' && event.label === null && Array.isArray(event.candidates) && event.candidates.length === 0) {
    return { type: 'clear-preview' };
  }
  if (!['preview', 'completed'].includes(event.phase) || !Number.isSafeInteger(event.attemptId) || event.attemptId! <= 0
    || !Array.isArray(event.candidates) || event.candidates.length < 1 || event.candidates.length > 3
    || event.candidates.some((choice, index, choices) => !choice || typeof choice.label !== 'string'
      || !Object.hasOwn(signText, choice.label) || !Number.isFinite(choice.distance) || choice.distance < 0
      || (index > 0 && choice.distance < choices[index - 1].distance))
    || new Set(event.candidates.map(choice => choice.label)).size !== event.candidates.length
    || event.label !== event.candidates[0].label) return { type: 'clear-preview' };
  const observation: SignObservation = { text: signText[event.label as keyof typeof signText],
    attemptId: event.attemptId!, observedAtMS: event.observedAtMS };
  // `matched` describes rolling-window calibration, not completion. Native
  // complete-gesture rankings currently always set it to false.
  return event.phase === 'completed'
    ? { type: 'recognized-sign', ...observation, label: event.label as SignLabel, emotion: isEmotion(event.emotion) ? event.emotion : 'neutral' }
    : { type: 'sign-preview', ...observation };
}
