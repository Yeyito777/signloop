import type { RefObject } from 'react';
import type { LipSync } from '../../../goose/src/voice/envelope.ts';

// Read on the render frame, not through a React state update on every audio tick.
export const gooseLipSync: RefObject<LipSync> = { current: { currentTime: () => 0 } };

export function claimLipSync(source: LipSync): () => void {
  gooseLipSync.current = source;
  return () => {
    // An old request's asynchronous cleanup must not reset a replacement clip.
    if (gooseLipSync.current === source) gooseLipSync.current = { currentTime: () => 0 };
  };
}
