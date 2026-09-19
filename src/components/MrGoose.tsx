import { Component, type ReactNode } from 'react';
import { StyleSheet, Text, View, type StyleProp, type ViewStyle } from 'react-native';
import { Canvas } from './goose/GooseCanvas';
import { GooseScene } from './goose/GooseScene';
import { colors } from './goose/settings';
import { useMotionPreferences } from '../hooks/useMotionPreferences';

class RenderBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    return this.state.failed
      ? <View style={styles.fallback}><Text>Mr. Goose couldn’t load. Please reopen the app.</Text></View>
      : this.props.children;
  }
}

export type MrGooseProps = {
  animationEnabled?: boolean;
  style?: StyleProp<ViewStyle>;
};

/** A self-contained 3D character. Give its container a width and height. */
export function MrGoose({ animationEnabled = true, style }: MrGooseProps) {
  const { reducedMotion, appActive } = useMotionPreferences();
  const animate = animationEnabled && !reducedMotion && appActive;
  return (
    <View style={[styles.container, style]} accessible accessibilityRole="image"
      accessibilityLabel="Mr. Goose, a plump Canada goose with white cheeks, bright eyes, and little brown wings.">
      <RenderBoundary>
        <Canvas orthographic camera={{ position: [0, 3.15, 8], zoom: 90, near: 0.1, far: 30 }}
          frameloop={animate ? 'always' : 'demand'}
          gl={{ antialias: true, alpha: false }}>
          <GooseScene animate={animate} reducedMotion={reducedMotion} />
        </Canvas>
      </RenderBoundary>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  fallback: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24 },
});
