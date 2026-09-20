import type { VoiceAdapter } from './contracts.ts';
import { getVoiceSettings, subscribeVoiceSettings } from './voiceSettings.ts';
import { assertNotAborted } from './abort.ts';
import type { fetchSpeech, SpeechClip } from './speechTransport.ts';

export function createVoiceAdapter(
  load: typeof fetchSpeech,
  play: (clip: SpeechClip, signal: AbortSignal, onStart?: () => void) => Promise<void>,
): VoiceAdapter {
  return {
    async speak(request, signal, onStart) {
      const controller = new AbortController();
      const cancel = () => controller.abort();
      signal.addEventListener('abort', cancel, { once: true });
      const unsubscribe = subscribeVoiceSettings(cancel);
      const timeout = setTimeout(cancel, 30_000);
      try {
        if (signal.aborted) cancel();
        assertNotAborted(controller.signal);
        const clip = await load(request, getVoiceSettings(), controller.signal);
        assertNotAborted(controller.signal);
        clearTimeout(timeout);
        await play(clip, controller.signal, onStart);
      } finally {
        clearTimeout(timeout);
        unsubscribe();
        signal.removeEventListener('abort', cancel);
      }
    },
  };
}
