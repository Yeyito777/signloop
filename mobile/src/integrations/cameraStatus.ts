import type { CameraStatusEvent } from '../../modules/signloop-camera';
import type { Framing } from './contracts';

/** Stale native events must not change a resumed session or reopen a paused one. */
export function framingFromCamera(event: CameraStatusEvent, active: boolean, captureId: number): Framing | null {
  if (!active || event.captureId !== captureId) return null;
  switch (event.status) {
    case 'starting': return 'finding';
    case 'searching': return 'hands-missing';
    case 'tracking': return event.handCount > 0 ? 'ready' : 'hands-missing';
    case 'denied': return 'camera-denied';
    case 'unavailable': return 'camera-unavailable';
    case 'error': return 'camera-error';
  }
}
