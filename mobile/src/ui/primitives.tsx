import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View, useWindowDimensions, type TextProps, type ViewStyle, type StyleProp, type PressableProps } from 'react-native';
import Animated, { cancelAnimation, useAnimatedStyle, useSharedValue, withSpring, withTiming } from 'react-native-reanimated';
import * as Haptics from 'expo-haptics';
import { motion, useReducedMotion } from './motion';
export { useReducedMotion } from './motion';
import Svg, { Circle, Path } from 'react-native-svg';
import { icons, iconStrokeWidth, iconViewBox, textStyles, tokens } from './theme';

export type IconName = keyof typeof icons;
const AnimatedPressable = Animated.createAnimatedComponent(Pressable);
const InverseContext = createContext(false);
export function InverseSurface({ children }: { children: ReactNode }) {
  return <InverseContext.Provider value={true}>{children}</InverseContext.Provider>;
}

/** UI-thread feedback follows interrupted / rapid presses without queued animations. */
export function Touch({ style, onPressIn, onPressOut, onPress, haptic = 'selection', ...props }: PressableProps & { haptic?: 'selection' | 'light' | false }) {
  const reduced = useReducedMotion();
  const [pressed, setPressed] = useState(false);
  const progress = useSharedValue(0);
  useEffect(() => { if (reduced) { cancelAnimation(progress); progress.value = 0; } }, [reduced, progress]);
  const animated = useAnimatedStyle(() => ({
    transform: [{ scale: 1 - progress.value * (1 - tokens.motion.pressedScale) },
      { translateY: progress.value * tokens.motion.pressedOffsetY }],
  }));
  const move = (down: boolean) => {
    cancelAnimation(progress);
    if (reduced) { progress.value = 0; return; }
    progress.value = down ? withTiming(1, { duration: motion.press, easing: motion.ease }) : withSpring(0, motion.touchSpring);
  };
  return <AnimatedPressable {...props}
    onPress={event => {
      if (haptic) void (haptic === 'light' ? Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light) : Haptics.selectionAsync()).catch(() => {});
      onPress?.(event);
    }}
    onPressIn={event => { setPressed(true); move(true); onPressIn?.(event); }}
    onPressOut={event => { setPressed(false); move(false); onPressOut?.(event); }}
    style={[typeof style === 'function' ? style({ pressed }) : style, animated]} />;
}
export function Icon({ name, size = 22, color, surface }: { name: IconName; size?: number; color?: string; surface?: string }) {
  const inverse = useContext(InverseContext);
  const ink = color ?? (inverse ? tokens.color.paper : tokens.color.ink);
  const background = surface ?? (inverse ? tokens.color.ink : tokens.color.paper);
  return <Svg width={size} height={size} viewBox={iconViewBox} fill="none" stroke={ink} strokeWidth={iconStrokeWidth} strokeLinecap="round" strokeLinejoin="round" accessible={false}>
    {icons[name].map((shape, i) => {
      const { tag, ...attributes } = shape;
      const props = { ...attributes } as Record<string, unknown>;
      if (props.fill === '$surface') props.fill = background;
      if (props.fill === 'currentColor') props.fill = ink;
      return tag === 'circle' ? <Circle key={i} {...props} /> : <Path key={i} {...props} />;
    })}
  </Svg>;
}

export function Copy({ role = 'body', style, ...props }: Omit<TextProps, 'role'> & { role?: keyof typeof textStyles }) {
  const inverse = useContext(InverseContext);
  const { fontScale } = useWindowDimensions();
  // Fabric can retain an intrinsic label width when the OS changes text size in an open screen.
  return <Text key={fontScale} {...props} style={[textStyles[role], { color: inverse ? tokens.color.paper : tokens.color.ink }, style]} />;
}

export function IconButton({ icon, label, onPress, disabled, filled = false }: { icon: IconName; label: string; onPress: () => void; disabled?: boolean; filled?: boolean }) {
  const inverse = useContext(InverseContext);
  return <Touch accessibilityRole="button" accessibilityLabel={label} accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.iconButton, filled && styles.iconFilled, pressed && (inverse ? styles.inversePressed : styles.pressed), disabled && styles.disabled]}>
    <Icon name={icon} />
  </Touch>;
}

export function Button({ children, onPress, icon, variant = 'primary', disabled, style }: {
  children: string; onPress: () => void; icon?: IconName; variant?: 'primary' | 'secondary' | 'plain' | 'ink'; disabled?: boolean; style?: StyleProp<ViewStyle>;
}) {
  const inverse = useContext(InverseContext);
  const foreground = variant === 'ink' || (inverse && variant === 'plain') ? tokens.color.paper : tokens.color.ink;
  return <Touch haptic={variant === 'primary' || variant === 'ink' ? 'light' : 'selection'} accessibilityRole="button" accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.button, variant === 'secondary' && styles.secondary, variant === 'plain' && styles.plain,
      variant !== 'plain' && variant !== 'ink' && !inverse && styles.shadow, inverse && variant !== 'plain' && styles.inverseButton,
      variant === 'ink' && styles.inkButton, pressed && styles.buttonPressed, disabled && styles.disabled, style]}>
    <Copy role="button" style={[styles.buttonText, { color: foreground }]}>{children}</Copy>
    {icon && <Icon name={icon} color={foreground} surface={inverse ? tokens.color.butter : undefined} />}
  </Touch>;
}

export function Wordmark() {
  return <Copy role="sectionTitle" accessibilityLabel="Signloop" style={styles.wordmark}>signloop<Copy role="sectionTitle" style={{ color: tokens.color.coral }}>.</Copy></Copy>;
}

export function Rule() { return <View style={styles.rule} />; }
const styles = StyleSheet.create({
  iconButton: { minWidth: 44, minHeight: 44, borderRadius: 16, alignItems: 'center', justifyContent: 'center' },
  iconFilled: { borderWidth: 1.5, borderColor: tokens.color.ink, backgroundColor: tokens.color.paper },
  pressed: { backgroundColor: tokens.color.captionShadow },
  inversePressed: { backgroundColor: `${tokens.color.paper}18` },
  disabled: { opacity: 0.4 },
  button: { minHeight: 56, paddingHorizontal: 20, paddingVertical: 14, borderRadius: 16, borderWidth: 1.5, borderColor: tokens.color.ink,
    backgroundColor: tokens.color.coral, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12 },
  buttonText: { flexShrink: 1, textAlign: 'center' },
  secondary: { backgroundColor: tokens.color.blue },
  plain: { backgroundColor: 'transparent', borderColor: 'transparent' },
  inkButton: { backgroundColor: tokens.color.ink, borderColor: tokens.color.ink, borderRadius: 999 },
  inverseButton: { backgroundColor: tokens.color.butter, borderColor: tokens.color.butter, borderRadius: 999 },
  shadow: { boxShadow: `0px 4px 0px ${tokens.color.ink}` },
  buttonPressed: { opacity: 0.92 },
  wordmark: { fontSize: 27, lineHeight: 34, letterSpacing: -0.8 },
  rule: { height: 1, backgroundColor: tokens.color.line },
});
