import type { AvatarMode } from '../integrations/contracts';

export type ConversationFocus = 'listening' | 'thinking' | 'speaking';

const GOOSE_SHARE: Record<ConversationFocus, number> = {
  listening: 0.42,
  thinking: 0.42,
  speaking: 0.56,
};

/** Sheets, pause, and Reduce Motion keep the listening split; the avatar can still change pose. */
export function conversationFocus(mode: AvatarMode, reducedMotion = false): ConversationFocus {
  if (reducedMotion || mode === 'idle' || mode === 'listening') return 'listening';
  return mode;
}

/** Space under the camera so the goose head does not overlap the preview. */
export const STAGE_CLEARANCE = 22;

/** Large goose by default. Speaking shrinks the camera preview; captions stay compact. */
export function conversationLayout(
  availableHeight: number,
  fontScale: number,
  focus: ConversationFocus = 'listening',
) {
  const height = Math.max(0, availableHeight);
  const caption = Math.min(height * 0.28, Math.max(height * 0.16, 108 * Math.max(1, fontScale)));
  const minCamera = Math.min(
    Math.max(height * (focus === 'speaking' ? 0.12 : 0.18), focus === 'speaking' ? 72 : 96),
    Math.max(0, height - caption),
  );
  let goose = height * GOOSE_SHARE[focus];
  let camera = height - caption - goose - STAGE_CLEARANCE;
  if (camera < minCamera) {
    camera = minCamera;
    goose = Math.max(0, height - caption - camera - STAGE_CLEARANCE);
  }
  return { camera, goose, caption, clearance: STAGE_CLEARANCE };
}
