import { useCallback, useEffect, useRef, useState } from 'react';
import {
  emptyEmotePlayer, emoteDurationMS, newEmoteRequest, updateEmotePlayer,
  type EmotePlayback, type EmoteProps, type EmoteRequest, type EmoteResult,
} from '../components/goose/emotes.ts';

/** UI state changes only when an action starts or ends, never on animation frames. */
export function useGooseEmote() {
  const [state, setState] = useState<{ request: EmoteRequest | null; result: EmoteResult | null }>({ request: null, result: null });
  const play = useCallback(() => {
    const request = newEmoteRequest();
    setState(current => current.request ? current : { request, result: null });
  }, []);
  const replay = useCallback(() => {
    setState({ request: newEmoteRequest(), result: null });
  }, []);
  const stop = useCallback(() => {
    setState(current => current.request
      ? { request: null, result: { id: current.request.id, status: 'cancelled' } }
      : current);
  }, []);
  const onEmoteEnd = useCallback((result: EmoteResult) => {
    setState(current => current.request?.id === result.id ? { request: null, result } : current);
  }, []);
  return { ...state, play, replay, stop, onEmoteEnd };
}

export function useEmotePlayback({ emote, onEmoteEnd }: EmoteProps, allowed: boolean) {
  const player = useRef(emptyEmotePlayer);
  const onEnd = useRef(onEmoteEnd);
  const [active, setActive] = useState<EmotePlayback | null>(null);
  useEffect(() => { onEnd.current = onEmoteEnd; }, [onEmoteEnd]);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    function sync() {
      const now = performance.now();
      const next = updateEmotePlayer(player.current, emote, allowed, now);
      player.current = next.player;
      setActive(next.player.active);
      for (const result of next.ended) onEnd.current?.(result);
      if (next.player.active) {
        const { request, startedAt } = next.player.active;
        timer = setTimeout(sync, Math.max(1, startedAt + emoteDurationMS[request.name] - now));
      }
    }
    sync();
    return () => { if (timer !== undefined) clearTimeout(timer); };
  }, [emote, allowed]);
  // Stop presenting a cancelled or replaced action before the effect reconciles it.
  return allowed && active?.request.id === emote?.id ? active : null;
}
