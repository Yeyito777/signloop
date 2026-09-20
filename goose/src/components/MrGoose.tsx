import { Component, type ReactNode, type RefObject } from 'react';
import { Platform, StyleSheet, Text, View, type StyleProp, type ViewStyle } from 'react-native';
import { useMotionPreferences } from '../hooks/useMotionPreferences';
import type { LipSync } from '../voice/envelope.ts';
import { Canvas } from './goose/GooseCanvas';
import { GooseScene } from './goose/GooseScene';
import { type GooseActivity, type GooseEmotion } from './goose/motion';
import { colors } from './goose/settings';

class RenderBoundary extends Component<{ children: ReactNode; fallback?: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    return this.state.failed
      ? <View style={styles.fallback}>{this.props.fallback ?? <Text>Mr. Goose couldn’t load. Please reopen the app.</Text>}</View>
      : this.props.children;
  }
}

export type MrGooseProps = {
  animationEnabled?: boolean;
  reducedMotion?: boolean;
  transparent?: boolean;
  fallback?: ReactNode;
  activity?: GooseActivity;
  emotion?: GooseEmotion;
  lipSync?: RefObject<LipSync>;
  style?: StyleProp<ViewStyle>;
};

/** A self-contained 3D character. Give its container a width and height. */
export function MrGoose({ animationEnabled = true, reducedMotion: appReducedMotion = false, transparent = false, fallback, activity = 'idle', emotion, lipSync, style }: MrGooseProps) {
  const { reducedMotion: systemReducedMotion, appActive } = useMotionPreferences();
  const reducedMotion = appReducedMotion || systemReducedMotion;
  const animate = animationEnabled && !reducedMotion && appActive;
  return (
    <View style={[styles.container, transparent && { backgroundColor: 'transparent' }, style]} accessible accessibilityRole="image"
      accessibilityLabel="Mr. Goose, a plump Canada goose with white cheeks, bright eyes, and little brown wings.">
      <RenderBoundary fallback={fallback}>
        <Canvas orthographic camera={{ position: [0, 3.15, 8], zoom: 110, near: 0.1, far: 30 }}
          frameloop={animate ? 'always' : 'demand'}
          gl={{ antialias: Platform.OS === 'web', alpha: transparent, premultipliedAlpha: false }}>
          <GooseScene background={transparent ? null : colors.background} animate={animate} reducedMotion={reducedMotion} activity={activity} emotion={emotion} lipSync={lipSync} />
        </Canvas>
      </RenderBoundary>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  fallback: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24 },
});
