import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { AccessibilityInfo } from 'react-native';
import { Easing, FadeIn, FadeOut, LinearTransition, ReduceMotion } from 'react-native-reanimated';
import { tokens } from './theme';

const ReducedMotionContext = createContext(true);

/** One subscription for the whole app; safe defaults while the OS preference loads. */
export function MotionProvider({ children }: { children: ReactNode }) {
  const [reduced, setReduced] = useState(true);
  useEffect(() => {
    let mounted = true;
    void AccessibilityInfo.isReduceMotionEnabled().then(value => {
      if (mounted) setReduced(value);
    }).catch(() => {});
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduced);
    return () => { mounted = false; subscription.remove(); };
  }, []);
  return <ReducedMotionContext.Provider value={reduced}>{children}</ReducedMotionContext.Provider>;
}

export const useReducedMotion = () => useContext(ReducedMotionContext);
export const motion = {
  press: tokens.motion.duration.press,
  feedback: tokens.motion.duration.feedback,
  transition: tokens.motion.duration.transition,
  navigation: tokens.motion.duration.navigation,
  scene: tokens.motion.duration.scene,
  ease: Easing.bezier(...tokens.motion.easing.standard),
  touchSpring: { ...tokens.motion.spring.touch, reduceMotion: ReduceMotion.System },
  sheetSpring: { ...tokens.motion.spring.sheet, overshootClamping: true },
};

export function useMotion() {
  const reduced = useReducedMotion();
  const preference = reduced ? ReduceMotion.Always : ReduceMotion.Never;
  return {
    reduced,
    enter: FadeIn.duration(motion.feedback).reduceMotion(preference),
    exit: FadeOut.duration(motion.feedback).reduceMotion(preference),
    layout: LinearTransition.duration(motion.transition).easing(motion.ease).reduceMotion(preference),
    sceneLayout: LinearTransition.duration(motion.scene).easing(motion.ease).reduceMotion(preference),
  };
}
