import { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import { SvgXml } from 'react-native-svg';
import type { AvatarProps, CameraProps, IntegrationKit } from './contracts';
import { gooseSvg, personSvg } from './demo-art';

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

function DemoAvatar({ mode, reducedMotion, style }: AvatarProps) {
  const bob = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    bob.setValue(0);
    if (reducedMotion) return;
    const animation = Animated.loop(Animated.sequence([
      Animated.timing(bob, { toValue: 1, duration: mode === 'speaking' ? 320 : 1800, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
      Animated.timing(bob, { toValue: 0, duration: mode === 'speaking' ? 320 : 1800, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
    ]));
    animation.start();
    return () => animation.stop();
  }, [mode, reducedMotion, bob]);
  return <View style={[styles.avatar, style]} accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
    <Animated.View style={{ width: '100%', height: '100%', transform: [{ translateY: bob.interpolate({ inputRange: [0, 1], outputRange: [0, -4] }) }] }}>
      <SvgXml xml={gooseSvg} width="100%" height="100%" />
    </Animated.View>
  </View>;
}

export const demoKit: IntegrationKit = {
  mode: 'demo', Camera: DemoCamera, Avatar: DemoAvatar,
  translation: {
    start(captureId, emit) {
      // One finite sample per capture generation. No recordings, recognition, or network calls.
      const timers = [
        setTimeout(() => emit({ type: 'draft', text: 'Could we find somewhere…' }), 2400),
        setTimeout(() => emit({ type: 'thinking' }), 4300),
        setTimeout(() => emit({ type: 'accepted', id: `demo-${captureId}`, text: 'Could we find somewhere a little quieter?', emotion: 'thoughtful' }), 5500),
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

const styles = StyleSheet.create({ avatar: { alignItems: 'center', justifyContent: 'center' } });
