import { createContext, forwardRef, useCallback, useContext, useEffect, useImperativeHandle, useRef, useState, type ComponentType, type ReactNode } from 'react';
import { AppState, StyleSheet, View, useWindowDimensions, type StyleProp, type ViewStyle } from 'react-native';
import { useFocusEffect, useIsFocused } from '@react-navigation/native';
import Animated, { cancelAnimation, interpolate, useAnimatedStyle, useSharedValue, withTiming, type SharedValue } from 'react-native-reanimated';
import type { AvatarProps } from '../integrations/contracts';
import { Copy } from './primitives';
import { motion, useReducedMotion } from './motion';
import { tokens } from './theme';

type Owner = 'home' | 'conversation';
type Frame = { x: number; y: number; width: number; height: number };
type Presentation = { Renderer: ComponentType<AvatarProps>; mode: AvatarProps['mode']; emotion: AvatarProps['emotion']; reducedMotion: boolean };
type StageContextValue = {
  frame: SharedValue<Frame>; home: SharedValue<number>; entrance: SharedValue<number>;
  homeViewport: SharedValue<{ top: number; bottom: number }>;
  presentation: Presentation | null;
  activate: (owner: Owner) => void;
  measure: (owner: Owner, frame: Frame) => void;
  present: (owner: Owner, presentation: Presentation) => void;
  prepareConversation: () => void;
};
const StageContext = createContext<StageContextValue | null>(null);
const EMPTY_FRAME = { x: 0, y: 0, width: 0, height: 0 };
const AVATAR_SIZE = 240;

export function SharedStageProvider({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  const frame = useSharedValue<Frame>(EMPTY_FRAME);
  const home = useSharedValue(1);
  const entrance = useSharedValue(1);
  const homeViewport = useSharedValue({ top: 0, bottom: 10000 });
  const [presentation, setPresentation] = useState<Presentation | null>(null);
  const owner = useRef<Owner>('home');
  const measuredOwner = useRef<Owner | null>(null);
  const hasFrame = useRef(false);
  const pending = useRef(false);
  const activate = useCallback((next: Owner) => {
    owner.current = next;
    if (next === 'home') { pending.current = false; entrance.value = 1; }
  }, [entrance]);
  const prepareConversation = useCallback(() => {
    pending.current = hasFrame.current && !reduced;
    entrance.value = pending.current ? 0 : 1;
  }, [entrance, reduced]);
  const measure = useCallback((next: Owner, bounds: Frame) => {
    if (next !== owner.current || bounds.width <= 0 || bounds.height <= 0) return;
    const flight = next === 'conversation' && pending.current;
    const changedScreen = measuredOwner.current !== next;
    const duration = reduced || !hasFrame.current ? 0 : changedScreen ? motion.scene : next === 'home' ? 0 : motion.transition;
    frame.value = withTiming(bounds, { duration, easing: motion.ease });
    home.value = withTiming(next === 'home' ? 1 : 0, { duration, easing: motion.ease });
    if (flight) {
      pending.current = false;
      entrance.value = withTiming(1, { duration: reduced ? 0 : motion.scene, easing: motion.ease });
    }
    measuredOwner.current = next;
    hasFrame.current = true;
  }, [entrance, frame, home, reduced]);
  const present = useCallback((next: Owner, props: Presentation) => {
    if (next === owner.current) setPresentation(props);
  }, []);
  useEffect(() => {
    if (reduced) { cancelAnimation(entrance); entrance.value = 1; }
  }, [entrance, reduced]);
  return <StageContext.Provider value={{ frame, home, entrance, homeViewport, presentation, activate, measure, present, prepareConversation }}>{children}</StageContext.Provider>;
}

export function useSharedStage() {
  const value = useContext(StageContext);
  if (!value) throw new Error('SharedStageProvider is required');
  return value;
}

export type StageSlotHandle = { measure: () => void };
/** Screens reserve space; the root renders exactly one replaceable avatar, above routes and below sheets. */
export const StageSlot = forwardRef<StageSlotHandle, Presentation & { owner: Owner; style?: StyleProp<ViewStyle> }>(function StageSlot({ owner, style, Renderer, mode, emotion, reducedMotion }, forwardedRef) {
  const ref = useRef<View>(null);
  const focused = useIsFocused();
  const { activate, measure: publishFrame, present } = useSharedStage();
  const measure = useCallback(() => {
    if (!focused) return;
    ref.current?.measureInWindow((x, y, width, height) => publishFrame(owner, { x, y, width, height }));
  }, [focused, owner, publishFrame]);
  useImperativeHandle(forwardedRef, () => ({ measure }), [measure]);
  useFocusEffect(useCallback(() => {
    activate(owner);
    const id = requestAnimationFrame(measure);
    return () => cancelAnimationFrame(id);
  }, [activate, measure, owner]));
  useEffect(() => {
    if (focused) present(owner, { Renderer, mode, emotion, reducedMotion });
  }, [Renderer, emotion, focused, mode, owner, present, reducedMotion]);
  return <View ref={ref} collapsable={false} pointerEvents="none" onLayout={measure} style={style} />;
});

/** Fixed-size render surface: travel transforms its container without resizing a future 3D canvas each frame. */
export function SharedStageLayer() {
  const { frame, home, homeViewport, presentation } = useSharedStage();
  const { height } = useWindowDimensions();
  const reduced = useReducedMotion();
  const [foreground, setForeground] = useState(AppState.currentState === 'active');
  useEffect(() => {
    const subscription = AppState.addEventListener('change', state => setForeground(state === 'active'));
    return () => subscription.remove();
  }, []);
  const avatar = useAnimatedStyle(() => {
    const rect = frame.value;
    return { opacity: rect.width > 0 ? 1 : 0, transform: [
      { translateX: rect.x + (rect.width - AVATAR_SIZE) / 2 },
      { translateY: rect.y + (rect.height - AVATAR_SIZE) / 2 },
      { scale: Math.min(rect.width, rect.height) / AVATAR_SIZE },
    ] };
  });
  const oval = useAnimatedStyle(() => {
    const rect = frame.value;
    const width = Math.min(rect.width * interpolate(home.value, [0, 1], [0.6, 0.85]), rect.height * 1.7);
    return {
      left: rect.x + (rect.width - width) / 2, top: rect.y + rect.height * 0.21,
      width, height: rect.height * 0.66,
      opacity: 1,
      transform: [{ rotate: `${interpolate(home.value, [0, 1], [-4, -8])}deg` }],
    };
  });
  const greeting = useAnimatedStyle(() => ({
    left: frame.value.x + frame.value.width - 96, top: frame.value.y + 18,
    opacity: home.value, transform: [{ scale: interpolate(home.value, [0, 1], [0.85, 1]) }, { rotate: '6deg' }],
  }));
  // Match Home's scroll viewport so the floating stage never covers its header or Start button.
  const clip = useAnimatedStyle(() => ({
    top: home.value * homeViewport.value.top,
    height: height - home.value * (homeViewport.value.top + Math.max(0, height - homeViewport.value.bottom)),
  }));
  const contents = useAnimatedStyle(() => ({ top: -home.value * homeViewport.value.top }));
  if (!presentation) return null;
  const { Renderer } = presentation;
  return <Animated.View pointerEvents="none" style={[styles.clip, clip]} accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
    <Animated.View style={[styles.contents, { height }, contents]}>
    <Animated.View style={[styles.oval, oval]} />
    <Animated.View style={[styles.avatar, avatar]}>
      <Renderer mode={presentation.mode} emotion={presentation.emotion} reducedMotion={reduced || presentation.reducedMotion || !foreground} style={StyleSheet.absoluteFill} />
    </Animated.View>
    <Animated.View style={[styles.hello, greeting]}><Copy role="sectionTitle" allowFontScaling={false}>Hello!</Copy></Animated.View>
    </Animated.View>
  </Animated.View>;
}

export function useConversationEntrance() {
  const { entrance } = useSharedStage();
  const camera = useAnimatedStyle(() => ({
    opacity: interpolate(entrance.value, [0, 0.55, 1], [0, 1, 1]),
    transform: [{ translateY: (1 - entrance.value) * 22 }, { scaleY: 0.86 + entrance.value * 0.14 }],
  }));
  const caption = useAnimatedStyle(() => ({
    opacity: interpolate(entrance.value, [0, 0.25, 1], [0, 0, 1], 'clamp'),
    transform: [{ translateY: (1 - entrance.value) * 12 }],
  }));
  return { camera, caption };
}

const styles = StyleSheet.create({
  clip: { position: 'absolute', left: 0, right: 0, overflow: 'hidden' },
  contents: { position: 'absolute', left: 0, right: 0 },
  oval: { position: 'absolute', backgroundColor: tokens.color.blue, borderRadius: 999 },
  avatar: { position: 'absolute', width: AVATAR_SIZE, height: AVATAR_SIZE },
  hello: { position: 'absolute', paddingHorizontal: 18, paddingVertical: 12, backgroundColor: tokens.color.paper, borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 20, borderBottomLeftRadius: 4 },
});
