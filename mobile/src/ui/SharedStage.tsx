import { createContext, forwardRef, useCallback, useContext, useEffect, useImperativeHandle, useRef, useState, type ComponentType, type ReactNode } from 'react';
import { AppState, StyleSheet, View, useWindowDimensions, type StyleProp, type ViewStyle } from 'react-native';
import { usePathname } from 'expo-router';
import { useFocusEffect, useIsFocused } from '@react-navigation/native';
import Animated, { cancelAnimation, interpolate, useAnimatedProps, useAnimatedStyle, useSharedValue, withTiming, type SharedValue } from 'react-native-reanimated';
import Svg, { Path } from 'react-native-svg';
import type { AvatarProps } from '../integrations/contracts';
import { motion, useReducedMotion } from './motion';
import { tokens } from './theme';

type Owner = 'home' | 'conversation';
type Frame = { x: number; y: number; width: number; height: number };
type Presentation = Omit<AvatarProps, 'style'> & { Renderer: ComponentType<AvatarProps> };
type StageContextValue = {
  frame: SharedValue<Frame>; home: SharedValue<number>; entrance: SharedValue<number>;
  homeViewport: SharedValue<{ top: number; bottom: number }>;
  presentation: Presentation | null;
  activate: (owner: Owner) => void;
  measure: (owner: Owner, frame: Frame) => void;
  present: (owner: Owner, presentation: Presentation) => void;
  clearEmote: (owner: Owner) => void;
  prepareConversation: () => void;
};
const StageContext = createContext<StageContextValue | null>(null);
const EMPTY_FRAME = { x: 0, y: 0, width: 0, height: 0 };
// Portrait surface fits the full 3D character. It never resizes during route travel.
const AVATAR_WIDTH = 320;
const AVATAR_HEIGHT = 440;
const AnimatedPath = Animated.createAnimatedComponent(Path);
// Matching cubic control points let one line change shape with the travelling stage.
const HOME_LOOP = [[1.04,.40],[.70,.38],[.59,.55],[.64,.63],[.70,.74],[.87,.76],[.87,.65],[.87,.53],[.68,.58],[.65,.73],[.60,.94],[.20,.92],[.14,.74],[.08,.60],[-.02,.53],[-.12,.67]];
const CONVERSATION_LOOP = [[.04,.32],[.10,.22],[.16,.22],[.20,.38],[.27,.61],[.24,.81],[.19,.67],[.15,.51],[.23,.35],[.32,.52],[.42,.74],[.61,.54],[.72,.55],[.84,.57],[.90,.76],[.98,.70]];

function loopPath(rect: Frame, progress: number, width: number) {
  'worklet';
  let path = '';
  for (let i = 0; i < HOME_LOOP.length; i++) {
    const x = CONVERSATION_LOOP[i][0] * width * (1 - progress) + (rect.x + HOME_LOOP[i][0] * rect.width) * progress;
    const y = rect.y + (CONVERSATION_LOOP[i][1] * (1 - progress) + HOME_LOOP[i][1] * progress) * rect.height;
    path += `${i === 0 ? 'M' : (i - 1) % 3 === 0 ? 'C' : ''}${x},${y} `;
  }
  return path;
}

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
    // Conversation slots can animate (speaking zoom). Track the reserved frame
    // immediately so the fixed canvas stays aligned; lean-in is a separate scale.
    const duration = reduced || !hasFrame.current || !changedScreen ? 0 : motion.scene;
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
  const clearEmote = useCallback((next: Owner) => {
    if (next === owner.current) setPresentation(current => current?.emote ? { ...current, emote: null } : current);
  }, []);
  useEffect(() => {
    if (reduced) { cancelAnimation(entrance); entrance.value = 1; }
  }, [entrance, reduced]);
  return <StageContext.Provider value={{ frame, home, entrance, homeViewport, presentation, activate, measure, present, clearEmote, prepareConversation }}>{children}</StageContext.Provider>;
}

export function useSharedStage() {
  const value = useContext(StageContext);
  if (!value) throw new Error('SharedStageProvider is required');
  return value;
}

export type StageSlotHandle = { measure: () => void };
/** Screens reserve space; the root renders exactly one replaceable avatar, above routes and below sheets. */
export const StageSlot = forwardRef<StageSlotHandle, Presentation & { owner: Owner; style?: StyleProp<ViewStyle>; children?: ReactNode }>(function StageSlot({ owner, style, Renderer, mode, emotion, reducedMotion, emote, onEmoteEnd, children }, forwardedRef) {
  const ref = useRef<View>(null);
  const focused = useIsFocused();
  const { activate, measure: publishFrame, present, clearEmote } = useSharedStage();
  const measure = useCallback(() => {
    if (!focused) return;
    ref.current?.measureInWindow((x, y, width, height) => publishFrame(owner, { x, y, width, height }));
  }, [focused, owner, publishFrame]);
  useImperativeHandle(forwardedRef, () => ({ measure }), [measure]);
  useFocusEffect(useCallback(() => {
    activate(owner);
    const id = requestAnimationFrame(measure);
    return () => { cancelAnimationFrame(id); clearEmote(owner); };
  }, [activate, measure, owner, clearEmote]));
  useEffect(() => {
    if (focused) present(owner, { Renderer, mode, emotion, reducedMotion, emote, onEmoteEnd });
  }, [Renderer, emotion, focused, mode, owner, present, reducedMotion, emote, onEmoteEnd]);
  return <View ref={ref} collapsable={false} pointerEvents={children && focused ? 'box-none' : 'none'} onLayout={measure} style={style}>
    {focused ? children : null}
  </View>;
});

/** Fixed-size render surface: travel transforms its container without resizing a future 3D canvas each frame. */
const SPEAKING_LEAN = 0.1;
const SPEAKING_LIFT = 12;

export function SharedStageLayer() {
  const pathname = usePathname();
  const { frame, home, homeViewport, presentation } = useSharedStage();
  const { width: windowWidth, height } = useWindowDimensions();
  const reduced = useReducedMotion();
  const lean = useSharedValue(0);
  const speaking = presentation?.mode === 'speaking' && !reduced && !presentation.reducedMotion;
  const [foreground, setForeground] = useState(AppState.currentState === 'active');
  useEffect(() => {
    const subscription = AppState.addEventListener('change', state => setForeground(state === 'active'));
    return () => subscription.remove();
  }, []);
  useEffect(() => {
    lean.value = withTiming(speaking ? 1 : 0, {
      duration: reduced ? 0 : speaking ? motion.scene : motion.transition,
      easing: motion.ease,
    });
  }, [lean, reduced, speaking]);
  const avatar = useAnimatedStyle(() => {
    const rect = frame.value;
    const fit = Math.min(rect.width / AVATAR_WIDTH, rect.height / AVATAR_HEIGHT);
    const zoom = 1 - home.value;
    return { opacity: rect.width > 0 ? 1 : 0, transform: [
      { translateX: rect.x + (rect.width - AVATAR_WIDTH) / 2 },
      { translateY: rect.y + (rect.height - AVATAR_HEIGHT) / 2 + zoom * SPEAKING_LIFT },
      { scale: fit * (1 + zoom * SPEAKING_LEAN) },
    ] };
  });
  const oval = useAnimatedStyle(() => {
    const rect = frame.value;
    const width = rect.width * 1.08;
    return {
      left: rect.x + rect.width * 0.19, top: rect.y + rect.height * 0.04,
      width, height: rect.height * 0.92,
      opacity: home.value,
      transform: [{ rotate: '-18deg' }],
    };
  });
  const homeLoop = useAnimatedProps(() => ({ d: loopPath(frame.value, home.value, windowWidth), opacity: frame.value.width > 0 ? home.value : 0 }));
  const conversationLoop = useAnimatedProps(() => ({
    d: loopPath(frame.value, home.value, windowWidth),
    opacity: frame.value.width > 0 ? 1 - home.value : 0,
    strokeWidth: 2.5 + lean.value * 1.5,
  }));
  // Match Home's scroll viewport so the floating stage never covers its header or Start button.
  const clip = useAnimatedStyle(() => ({
    top: home.value * homeViewport.value.top,
    height: height - home.value * (homeViewport.value.top + Math.max(0, height - homeViewport.value.bottom)),
  }));
  const contents = useAnimatedStyle(() => ({ top: -home.value * homeViewport.value.top }));
  if (!presentation || (pathname !== '/' && pathname !== '/conversation')) return null;
  const { Renderer } = presentation;
  return <Animated.View pointerEvents="none" style={[styles.clip, clip]} accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
    <Animated.View style={[styles.contents, { height }, contents]}>
    <Animated.View style={[styles.oval, oval]} />
    <Animated.View style={[styles.avatar, avatar]}>
      <Renderer mode={presentation.mode} emotion={presentation.emotion} emote={presentation.emote} onEmoteEnd={presentation.onEmoteEnd} reducedMotion={reduced || presentation.reducedMotion || !foreground} style={StyleSheet.absoluteFill} />
    </Animated.View>
    <Svg width={windowWidth} height={height} style={StyleSheet.absoluteFill} accessible={false}>
      <AnimatedPath animatedProps={homeLoop} fill="none" stroke={tokens.color.paper} strokeWidth={3.5} strokeLinecap="round" />
      <AnimatedPath animatedProps={conversationLoop} fill="none" stroke={tokens.color.coral} strokeLinecap="round" />
    </Svg>
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
  avatar: { position: 'absolute', width: AVATAR_WIDTH, height: AVATAR_HEIGHT },
});
