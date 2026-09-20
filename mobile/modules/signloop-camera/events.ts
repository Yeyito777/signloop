/** Version 3 separates rolling previews from completed gestures with ranked choices. */
export const RECOGNITION_VERSION = 3;
export type CameraStatus = 'starting' | 'searching' | 'tracking' | 'body-missing' | 'denied' | 'unavailable' | 'error'
  | 'model-missing' | 'recognizer-loading' | 'references-missing' | 'references-invalid';
export type CameraStatusEvent = { captureId: number; status: CameraStatus; handCount: number; message: string };
/** A ranking, not a caption or calibrated probability. Even matched results need confirmation. */
export type SignPredictionEvent = {
  captureId: number;
  engine: 'basic-temporal-v2';
  phase: 'preview' | 'completed' | 'cleared';
  attemptId: number | null;
  candidates: { label: string; distance: number }[];
  label: string | null;
  matched: boolean;
  observedAtMS: number;
};
