import type { Framing } from '../integrations/contracts';

/** Presentation only. Capture and recognition must continue to consume the unfiltered scanner events. */
export function createFramingFeedback(emit: (framing: Framing) => void) {
  let shown: Framing = 'finding';
  let timer: ReturnType<typeof setTimeout> | undefined;
  let version = 0;
  const cancel = () => { version++; clearTimeout(timer); };
  const commit = (next: Framing) => { if (shown !== next) { shown = next; emit(next); } };
  return {
    update(next: Framing, active: boolean) {
      cancel();
      if (!active) return;
      // Permission/device failures must never wait behind a friendly tracking animation.
      if (next.startsWith('camera-')) { commit(next); return; }
      if (shown === next) return;
      const current = version;
      timer = setTimeout(() => { if (version === current) commit(next); }, next === 'ready' ? 300 : 450);
    },
    reset() { cancel(); commit('finding'); },
    dispose: cancel,
  };
}
