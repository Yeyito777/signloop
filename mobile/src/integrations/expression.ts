import { isEmotion, type Emotion } from '../../../goose/src/emotion.ts';
import type { ExpressionEvent, ExpressionStatus } from '../../modules/signloop-camera/events.ts';
import type { Session } from '../session/model.ts';

export const EXPRESSION_FRESH_MS = 600;
const statuses: readonly ExpressionStatus[] = ['active', 'neutral', 'holding', 'unknown', 'ambiguous',
  'no-face', 'no-profile', 'profile-invalid', 'model-missing', 'unavailable', 'wrong-camera', 'face-forward', 'stale'];
const moodNames: Record<Emotion, string> = {
  neutral: 'Neutral', joy: 'Joy', sadness: 'Sadness', anger: 'Anger', fear: 'Fear', disgust: 'Disgust',
};

function liveExpression(event: ExpressionEvent) {
  return event.status === 'active' || event.status === 'holding';
}

/** Only stable, fresh native matches can change the live character. */
export function expressionFromCamera(event: ExpressionEvent, captureId: number, now = Date.now()): ExpressionEvent | null {
  if (event.captureId !== captureId || !Number.isFinite(event.observedAtMS)
    || now - event.observedAtMS > EXPRESSION_FRESH_MS || event.observedAtMS > now + 100) return null;
  if (!statuses.includes(event.status) || !isEmotion(event.emotion)
    || (liveExpression(event) && event.emotion === 'neutral')) {
    return { ...event, status: 'unavailable', emotion: 'neutral' };
  }
  return { ...event, emotion: liveExpression(event) ? event.emotion : 'neutral' };
}

export function conversationEmotion(state: Session, now = Date.now()): Emotion {
  if (state.paused || state.sheet) return 'neutral';
  // Preparation, queue playback and replay all own their immutable phrase emotion.
  if (state.speech) return state.speech.emotion;
  const event = state.expression;
  return event && event.captureId === state.captureId && now - event.observedAtMS <= EXPRESSION_FRESH_MS
    && liveExpression(event) ? event.emotion : 'neutral';
}

export function expressionNotice(event: ExpressionEvent | null): string {
  switch (event?.status) {
    case 'no-profile': return 'Learning your rest face';
    case 'profile-invalid': return 'Using live face tracking';
    case 'model-missing': return 'Expression tracking needs an app update';
    case 'wrong-camera': return 'Expression tracking needs the camera used during setup';
    case 'face-forward': return 'Face the camera for expression tracking';
    default: return '';
  }
}

/** Testing HUD: the mood actually driving the goose, plus why it may be stuck on Neutral. */
export function moodPresentation(state: Session, now = Date.now()) {
  const mood = moodNames[conversationEmotion(state, now)];
  if (state.paused || state.sheet) return { mood: 'Neutral', detail: 'Paused' };
  if (state.speech) {
    return { mood, detail: state.speech.started ? 'Speaking this phrase' : 'Voice for this phrase' };
  }
  const event = state.expression;
  if (!event || event.captureId !== state.captureId) return { mood: 'Neutral', detail: 'Waiting for face' };
  const setup = expressionNotice(event);
  if (setup) return { mood: 'Neutral', detail: setup };
  switch (event.status) {
    case 'active': return { mood, detail: 'Live face' };
    case 'holding': return { mood, detail: 'Holding this expression' };
    case 'neutral': return { mood: 'Neutral', detail: 'Relaxed face' };
    case 'no-face': return { mood: 'Neutral', detail: 'No face in view' };
    case 'stale': return { mood: 'Neutral', detail: 'Face tracking paused' };
    case 'unknown': return { mood: 'Neutral', detail: 'Not in your expression profile' };
    case 'ambiguous': return { mood: 'Neutral', detail: 'Expression unclear' };
    case 'unavailable': return { mood: 'Neutral', detail: 'Face tracking is not reading expressions' };
    default: return { mood: 'Neutral', detail: 'Using neutral' };
  }
}
