import type { AvatarMode } from '../integrations/contracts';

export type ConversationFocus = 'listening' | 'thinking' | 'speaking';

const GOOSE_SHARE: Record<ConversationFocus, number> = {
  listening: 0.34,
  thinking: 0.34,
  speaking: 0.34,
};

/** Sheets, pause, and Reduce Motion keep the listening split; the avatar can still change pose. */
export function conversationFocus(mode: AvatarMode, reducedMotion = false): ConversationFocus {
  if (reducedMotion || mode === 'idle' || mode === 'listening') return 'listening';
  return mode;
}

/** Space under the camera so the goose head does not overlap the preview. */
export const STAGE_CLEARANCE = 22;

/** Full-width landscape camera tall enough for face, shoulders, and hands. Extra space goes to the goose. */
export function conversationLayout(
  availableHeight: number,
  fontScale: number,
  focus: ConversationFocus = 'listening',
  availableWidth = 0,
) {
  const height = Math.max(0, availableHeight);
  const width = Math.max(0, availableWidth);
  const caption = Math.min(height * 0.22, Math.max(height * 0.12, 88 * Math.max(1, fontScale)));
  const minGoose = Math.min(height * 0.28, 140);
  let goose = height * GOOSE_SHARE[focus];
  let camera = height - caption - goose - STAGE_CLEARANCE;
  // 4:3 keeps a landscape strip without cropping the signing pose the way 16:9 does.
  const landscape = width > 0 ? width * 3 / 4 : camera;
  if (camera > landscape) {
    goose += camera - landscape;
    camera = landscape;
  }
  if (goose < minGoose) {
    goose = minGoose;
    camera = Math.max(0, height - caption - goose - STAGE_CLEARANCE);
  }
  return { camera, goose, caption, clearance: STAGE_CLEARANCE };
}
