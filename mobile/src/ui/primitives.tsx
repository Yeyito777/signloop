import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View, type TextProps, type ViewStyle, type StyleProp, type PressableProps } from 'react-native';
import Animated, { cancelAnimation, useAnimatedStyle, useSharedValue, withSpring, withTiming } from 'react-native-reanimated';
import * as Haptics from 'expo-haptics';
import { motion, useReducedMotion } from './motion';
export { useReducedMotion } from './motion';
import Svg, { Circle, Path } from 'react-native-svg';
import { icons, iconStrokeWidth, iconViewBox, textStyles, tokens } from './theme';

export type IconName = keyof typeof icons;
const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

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
export function Icon({ name, size = 22, color = tokens.color.ink, surface = tokens.color.paper }: { name: IconName; size?: number; color?: string; surface?: string }) {
  return <Svg width={size} height={size} viewBox={iconViewBox} fill="none" stroke={color} strokeWidth={iconStrokeWidth} strokeLinecap="round" strokeLinejoin="round" accessible={false}>
    {icons[name].map((shape, i) => {
      const { tag, ...attributes } = shape;
      const props = { ...attributes } as Record<string, unknown>;
      if (props.fill === '$surface') props.fill = surface;
      if (props.fill === 'currentColor') props.fill = color;
      return tag === 'circle' ? <Circle key={i} {...props} /> : <Path key={i} {...props} />;
    })}
  </Svg>;
}

export function Copy({ role = 'body', style, ...props }: Omit<TextProps, 'role'> & { role?: keyof typeof textStyles }) {
  return <Text {...props} style={[textStyles[role], { color: tokens.color.ink }, style]} />;
}

export function IconButton({ icon, label, onPress, disabled, filled = false }: { icon: IconName; label: string; onPress: () => void; disabled?: boolean; filled?: boolean }) {
  return <Touch accessibilityRole="button" accessibilityLabel={label} accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.iconButton, filled && styles.iconFilled, pressed && styles.pressed, disabled && styles.disabled]}>
    <Icon name={icon} />
  </Touch>;
}

export function Button({ children, onPress, icon, variant = 'primary', disabled, style }: {
  children: string; onPress: () => void; icon?: IconName; variant?: 'primary' | 'secondary' | 'plain'; disabled?: boolean; style?: StyleProp<ViewStyle>;
}) {
  return <Touch haptic={variant === 'primary' ? 'light' : 'selection'} accessibilityRole="button" accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.button, variant === 'secondary' && styles.secondary, variant === 'plain' && styles.plain,
      variant !== 'plain' && styles.shadow, pressed && styles.buttonPressed, disabled && styles.disabled, style]}>
    <Copy role="button" style={[styles.buttonText, variant === 'primary' && { color: tokens.color.inkStrong }]}>{children}</Copy>
    {icon && <Icon name={icon} color={variant === 'primary' ? tokens.color.inkStrong : tokens.color.ink} />}
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
  disabled: { opacity: 0.4 },
  button: { minHeight: 56, paddingHorizontal: 20, paddingVertical: 14, borderRadius: 16, borderWidth: 1.5, borderColor: tokens.color.ink,
    backgroundColor: tokens.color.coral, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12 },
  buttonText: { flexShrink: 1, textAlign: 'center' },
  secondary: { backgroundColor: tokens.color.blue },
  plain: { backgroundColor: 'transparent', borderColor: 'transparent' },
  shadow: { boxShadow: `0px 4px 0px ${tokens.color.ink}` },
  buttonPressed: { opacity: 0.92 },
  wordmark: { fontSize: 27, lineHeight: 34, letterSpacing: -0.8 },
  rule: { height: 1, backgroundColor: tokens.color.line },
});
