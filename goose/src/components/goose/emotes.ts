import type { GooseActivity, GoosePose } from './motion.ts';

export type GooseEmote = 'dance';
export type EmoteRequest = Readonly<{ id: string; name: GooseEmote }>;
export type EmoteResult = Readonly<{ id: string; status: 'completed' | 'cancelled' | 'skipped' }>;
export type EmoteProps = { emote?: EmoteRequest | null; onEmoteEnd?: (result: EmoteResult) => void };
export type EmotePlayback = Readonly<{ request: EmoteRequest; startedAt: number }>;
export type EmotePlayer = Readonly<{ active: EmotePlayback | null; lastRequestId: string | null }>;

export const emoteDurationMS: Record<GooseEmote, number> = { dance: 3000 };
export const emptyEmotePlayer: EmotePlayer = { active: null, lastRequestId: null };
let requestSequence = 0;
export function newEmoteRequest(name: GooseEmote = 'dance'): EmoteRequest {
  return { id: `emote-${++requestSequence}`, name };
}

export function canPlayEmote(animate: boolean, activity: GooseActivity) {
  return animate && (activity === 'idle' || activity === 'watching');
}

/** A monotonic clock owns completion even when the canvas renders slowly or fails. */
export function updateEmotePlayer(player: EmotePlayer, request: EmoteRequest | null | undefined, allowed: boolean, now: number) {
  let { active, lastRequestId } = player;
  const ended: EmoteResult[] = [];
  if (active && (!allowed || active.request.id !== request?.id)) {
    ended.push({ id: active.request.id, status: 'cancelled' });
    active = null;
  }
  if (request && request.id !== lastRequestId) {
    lastRequestId = request.id;
    if (allowed) active = { request, startedAt: now };
    else ended.push({ id: request.id, status: 'skipped' });
  }
  if (active && now - active.startedAt >= emoteDurationMS[active.request.name]) {
    ended.push({ id: active.request.id, status: 'completed' });
    active = null;
  }
  return { player: { active, lastRequestId } satisfies EmotePlayer, ended };
}

const smooth = (value: number) => {
  const t = Math.min(1, Math.max(0, value));
  return t * t * (3 - 2 * t);
};

/** Feet stay planted. The pose offsets fade to zero at both ends. */
export function emoteOffset(name: GooseEmote, elapsedMS: number): Partial<GoosePose> {
  const t = elapsedMS / 1000;
  if (!Number.isFinite(t) || t <= 0 || elapsedMS >= emoteDurationMS[name]) return {};
  const envelope = smooth(t / 0.25) * (1 - smooth((t - 2.65) / 0.35));
  const dancing = 1 - smooth((t - 2.2) / 0.3);
  const beat = Math.sin((t - 0.25) * Math.PI * 4);
  const sway = Math.sin((t - 0.25) * Math.PI * 2);
  const finish = smooth((t - 2.2) / 0.3);
  return {
    bob: envelope * (0.055 + 0.045 * beat * dancing),
    bodyYaw: envelope * 0.34 * sway * dancing,
    tilt: envelope * 0.14 * sway * dancing,
    pitch: envelope * (-0.04 + 0.055 * beat * dancing),
    leftWing: envelope * (0.43 + 0.34 * beat * dancing + 0.3 * finish),
    rightWing: envelope * (0.43 - 0.34 * beat * dancing + 0.3 * finish),
  };
}
