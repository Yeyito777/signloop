import { useEffect, useMemo, useRef, useState } from 'react';
import { Linking, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import Animated, { interpolateColor, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';
import { router } from 'expo-router';
import type { Framing, IntegrationKit } from '../integrations/contracts';
import type { Action } from './model';
import { createFramingFeedback } from './framingFeedback';
import { Button, Copy, Icon, IconButton, type IconName } from '../ui/primitives';
import { motion, useMotion } from '../ui/motion';
import { tokens } from '../ui/theme';

const copy: Record<Framing, { title: string; hint: string; icon: IconName }> = {
  finding: { title: 'Find your frame', hint: 'Keep your face and both hands in view.', icon: 'frame' },
  ready: { title: 'You’re in view', hint: '', icon: 'check' },
  'hands-missing': { title: 'Hands out of view', hint: 'Bring both hands inside the corners.', icon: 'hand' },
  'too-close': { title: 'A little more room', hint: 'Move a little farther back.', icon: 'frame' },
  'too-far': { title: 'A little closer', hint: 'Move closer so your hands are clear.', icon: 'frame' },
  'low-light': { title: 'More light needed', hint: 'Try facing a window or a light.', icon: 'sun' },
  away: { title: 'Come back into view', hint: 'Keep your face and hands in the frame.', icon: 'frame' },
  'camera-denied': { title: 'Camera access needed', hint: 'Allow camera access in Settings, then return and tap Resume.', icon: 'frame' },
  'camera-unavailable': { title: 'Camera unavailable here', hint: 'Open the development build on an iPhone to try hand tracking.', icon: 'frame' },
  'camera-error': { title: 'Camera couldn’t start', hint: 'Try starting the camera again.', icon: 'frame' },
};

function useFramingFeedback(framing: Framing, active: boolean) {
  const [shown, setShown] = useState<Framing>('finding');
  const feedback = useMemo(() => createFramingFeedback(setShown), []);
  const wasActive = useRef(active);
  useEffect(() => {
    if (active && !wasActive.current) feedback.reset();
    wasActive.current = active;
    feedback.update(framing, active);
  }, [active, feedback, framing]);
  useEffect(() => () => feedback.dispose(), [feedback]);
  return framing.startsWith('camera-') ? framing : shown;
}

export function CameraGuidance({ framing, active, mode, dispatch, demo }: {
  framing: Framing; active: boolean; mode: IntegrationKit['mode']; dispatch: (action: Action) => void; demo: boolean;
}) {
  const shown = useFramingFeedback(framing, active);
  const { enter, exit, reduced } = useMotion();
  const ready = shown === 'ready';
  const blocked = shown.startsWith('camera-');
  const issue = !ready && shown !== 'finding';
  const guidance = mode !== 'demo' && shown === 'ready'
    ? { title: 'Hand detected', hint: '', icon: 'check' as const }
    : mode !== 'demo' && shown === 'finding'
      ? { title: 'Finding your hands', hint: 'Bring your hands inside the corners.', icon: 'frame' as const }
      : copy[shown];
  const settled = useSharedValue(0);
  useEffect(() => { settled.value = withTiming(ready ? 1 : 0, { duration: reduced ? 0 : motion.transition, easing: motion.ease }); }, [ready, reduced, settled]);
  const badge = useAnimatedStyle(() => ({ backgroundColor: issue ? tokens.color.cautionSurface : interpolateColor(settled.value, [0, 1], [tokens.color.paper, tokens.color.successSurface]) }));
  return <>
    {!blocked && <View pointerEvents="none" style={[styles.guide, { bottom: demo ? 98 : 62 }]}>
      {(['tl', 'tr', 'bl', 'br'] as const).map(corner => <Corner key={corner} corner={corner} settled={settled} reduced={reduced} />)}
    </View>}
    {blocked && <View pointerEvents="none" style={styles.blockedSurface} />}
    {blocked && <View pointerEvents="none" style={styles.blockedIcon}><Icon name="frame" size={36} /></View>}
    <View style={styles.cameraTop}>
      <Animated.View style={[styles.badge, badge]}>
        <Animated.View key={shown} entering={enter} style={styles.badgeContent}>
          <Icon name={guidance.icon} size={20} color={ready ? tokens.color.successInk : tokens.color.ink} />
          <Copy role="label" accessibilityLiveRegion="polite" style={{ flexShrink: 1, color: ready ? tokens.color.successInk : tokens.color.ink }}>{guidance.title}</Copy>
        </Animated.View>
      </Animated.View>
      <IconButton filled icon="pause" label="Pause camera and voice" onPress={() => dispatch({ type: 'pause' })} />
    </View>
    {!!guidance.hint && <Animated.View key={shown} entering={enter} exiting={exit} style={[styles.hint, { bottom: demo ? 60 : 12 }]}>
      <Copy role="supporting" style={styles.hintText}>{guidance.hint}</Copy>
      {shown === 'camera-denied' && <Button variant="plain" onPress={() => { dispatch({ type: 'pause' }); void Linking.openSettings(); }}>Open Settings</Button>}
      {shown === 'camera-unavailable' && <Button variant="plain" onPress={() => router.replace('/conversation?demo=1')}>Try the UI demo</Button>}
      {shown === 'camera-error' && <Button variant="plain" icon="repeat" onPress={() => dispatch({ type: 'retry' })}>Try camera again</Button>}
    </Animated.View>}
  </>;
}

function Corner({ corner, settled, reduced }: { corner: 'tl' | 'tr' | 'bl' | 'br'; settled: ReturnType<typeof useSharedValue<number>>; reduced: boolean }) {
  const right = corner.endsWith('r');
  const bottom = corner.startsWith('b');
  const animated = useAnimatedStyle(() => ({
    opacity: 1 - settled.value * 0.35,
    borderColor: interpolateColor(settled.value, [0, 1], [tokens.color.paper, tokens.color.successSurface]),
    transform: [{ translateX: reduced ? 0 : settled.value * (right ? -4 : 4) }, { translateY: reduced ? 0 : settled.value * (bottom ? -4 : 4) }],
  }));
  const position: StyleProp<ViewStyle> = [right ? styles.right : styles.left, bottom ? styles.bottom : styles.top];
  return <Animated.View style={[styles.corner, position, animated]} />;
}

const styles = StyleSheet.create({
  guide: { position: 'absolute', top: 82, left: 26, right: 26 },
  corner: { position: 'absolute', width: 28, height: 28, borderColor: tokens.color.paper },
  left: { left: 0, borderLeftWidth: 2.5 }, right: { right: 0, borderRightWidth: 2.5 },
  top: { top: 0, borderTopWidth: 2.5, borderTopLeftRadius: 9, borderTopRightRadius: 9 },
  bottom: { bottom: 0, borderBottomWidth: 2.5, borderBottomLeftRadius: 9, borderBottomRightRadius: 9 },
  cameraTop: { position: 'absolute', top: 12, left: 12, right: 12, flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 },
  badge: { minHeight: 44, borderRadius: 14, paddingVertical: 10, paddingHorizontal: 12, flexShrink: 1 },
  badgeContent: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  hint: { position: 'absolute', left: 12, right: 12, paddingHorizontal: 12, paddingVertical: 10, borderRadius: 14, backgroundColor: tokens.color.paper },
  hintText: { textAlign: 'center' },
  blockedSurface: { ...StyleSheet.absoluteFillObject, backgroundColor: tokens.color.blue },
  blockedIcon: { position: 'absolute', left: 0, right: 0, top: '30%', alignItems: 'center' },
});
