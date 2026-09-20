import { useEffect } from 'react';
import { View } from 'react-native';
import { SvgXml } from 'react-native-svg';
import type { CameraProps, IntegrationKit } from './contracts';
import { personSvg } from './demo-art';
import { GooseAvatar } from './GooseAvatar';

function DemoCamera({ active, captureId, framing, onFraming, style }: CameraProps) {
  useEffect(() => {
    if (!active || framing !== 'finding') return;
    const timer = setTimeout(() => onFraming('ready', captureId), 1800);
    return () => clearTimeout(timer);
  }, [active, captureId, framing, onFraming]);
  return <View style={[{ overflow: 'hidden' }, style]} accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
    <SvgXml xml={personSvg} width="100%" height="100%" />
  </View>;
}

export const demoKit: IntegrationKit = {
  mode: 'demo', Camera: DemoCamera, Avatar: GooseAvatar,
  translation: {
    start(captureId, emit) {
      // One finite sample per capture generation. No recordings, recognition, or network calls.
      const timers = [
        setTimeout(() => emit({ type: 'draft', text: 'Could we find somewhere…' }), 2400),
        setTimeout(() => emit({ type: 'thinking' }), 4300),
        setTimeout(() => emit({ type: 'accepted', id: `demo-${captureId}`, text: 'Could we find somewhere a little quieter?', emotion: 'neutral' }), 5500),
      ];
      return () => timers.forEach(clearTimeout);
    },
  },
  voice: {
    speak(_text, signal, onPlaybackStart) {
      // Silent playback simulation. ElevenLabs must replace this adapter before live use.
      return new Promise<void>((resolve, reject) => {
        if (signal.aborted) { reject(new Error('Playback cancelled')); return; }
        onPlaybackStart?.();
        const cancel = () => { clearTimeout(timer); reject(new Error('Playback cancelled')); };
        const timer = setTimeout(() => { signal.removeEventListener('abort', cancel); resolve(); }, 3200);
        signal.addEventListener('abort', cancel, { once: true });
      });
    },
  },
};
