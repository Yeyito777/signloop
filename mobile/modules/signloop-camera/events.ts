import type { Emotion } from '../../../goose/src/emotion';
/** Version 5 includes live expression events and expression snapshots on predictions. */
export const RECOGNITION_VERSION = 5;
export type ExpressionStatus = 'active' | 'neutral' | 'holding' | 'unknown' | 'ambiguous'
  | 'no-face' | 'no-profile' | 'profile-invalid' | 'model-missing' | 'unavailable'
  | 'wrong-camera' | 'face-forward' | 'stale';
export type ExpressionEvent = {
  captureId: number;
  observedAtMS: number;
  status: ExpressionStatus;
  emotion: Emotion;
};
export type CameraStatus = 'starting' | 'searching' | 'tracking' | 'body-missing' | 'denied' | 'unavailable' | 'error'
  | 'model-missing' | 'recognizer-loading' | 'references-missing' | 'references-invalid';
export type CameraStatusEvent = { captureId: number; status: CameraStatus; handCount: number; message: string };
/** A ranking, not a caption or calibrated probability. Even matched results need confirmation. */
export type SignPredictionEvent = {
  captureId: number;
  engine: 'basic-temporal-v3';
  phase: 'preview' | 'completed' | 'cleared';
  attemptId: number | null;
  candidates: { label: string; distance: number }[];
  label: string | null;
  matched: boolean;
  observedAtMS: number;
  /** Time-aligned native summary of the sign's input window; absent means neutral. */
  emotion?: Emotion;
};
