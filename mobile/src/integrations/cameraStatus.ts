import { RECOGNITION_VERSION, type CameraStatusEvent } from '../../modules/signloop-camera/events.ts';
import type { Framing } from './contracts';

export function cameraAvailability(nativeModule: { recognitionVersion?: number } | null): Framing | null {
  if (!nativeModule) return 'camera-unavailable';
  return nativeModule.recognitionVersion === RECOGNITION_VERSION ? null : 'camera-update-required';
}

/** Stale native events must not change a resumed session or reopen a paused one. */
export function framingFromCamera(event: CameraStatusEvent, active: boolean, captureId: number): Framing | null {
  if (!active || event.captureId !== captureId) return null;
  switch (event.status) {
    case 'starting': return 'finding';
    case 'searching': return 'hands-missing';
    case 'tracking': return event.handCount > 0 ? 'ready' : 'hands-missing';
    case 'body-missing': return 'body-missing';
    case 'recognizer-loading': return 'recognizer-loading';
    case 'references-missing': return 'recognizer-missing';
    case 'references-invalid': return 'recognizer-error';
    case 'model-missing': return 'camera-model-missing';
    case 'denied': return 'camera-denied';
    case 'unavailable': return 'camera-unavailable';
    case 'error': return 'camera-error';
  }
}
