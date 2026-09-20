import { isEmotion, type Emotion } from '../../../goose/src/emotion.ts';
import type { ExpressionEvent, ExpressionStatus } from '../../modules/signloop-camera/events.ts';
import type { Session } from '../session/model.ts';

export const EXPRESSION_FRESH_MS = 600;
const statuses: readonly ExpressionStatus[] = ['active', 'neutral', 'holding', 'unknown', 'ambiguous',
  'no-face', 'no-profile', 'profile-invalid', 'model-missing', 'unavailable', 'wrong-camera', 'face-forward', 'stale'];

/** Only stable, fresh native matches can change the live character. */
export function expressionFromCamera(event: ExpressionEvent, captureId: number, now = Date.now()): ExpressionEvent | null {
  if (event.captureId !== captureId || !Number.isFinite(event.observedAtMS)
    || now - event.observedAtMS > EXPRESSION_FRESH_MS || event.observedAtMS > now + 100) return null;
  if (!statuses.includes(event.status) || !isEmotion(event.emotion)
    || (event.status === 'active' && event.emotion === 'neutral')) {
    return { ...event, status: 'unavailable', emotion: 'neutral' };
  }
  return { ...event, emotion: event.status === 'active' ? event.emotion : 'neutral' };
}

export function conversationEmotion(state: Session, now = Date.now()): Emotion {
  if (state.paused || state.sheet) return 'neutral';
  // Preparation, queue playback and replay all own their immutable phrase emotion.
  if (state.speech) return state.speech.emotion;
  const event = state.expression;
  return event && event.captureId === state.captureId && now - event.observedAtMS <= EXPRESSION_FRESH_MS
    && event.status === 'active' ? event.emotion : 'neutral';
}

export function expressionNotice(event: ExpressionEvent | null): string {
  switch (event?.status) {
    case 'no-profile': return 'Expression setup needed · using neutral delivery';
    case 'profile-invalid': return 'Expression setup needs replacing · using neutral delivery';
    case 'model-missing': return 'Expression tracking needs an app update';
    case 'wrong-camera': return 'Expression tracking needs the camera used during setup';
    case 'face-forward': return 'Face the camera for expression tracking';
    default: return '';
  }
}
