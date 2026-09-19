import { useEffect, useState } from 'react';
import { AccessibilityInfo, AppState } from 'react-native';

export function useMotionPreferences() {
  // Stay still until the OS preference has been read.
  const [reducedMotion, setReducedMotion] = useState(true);
  const [appActive, setAppActive] = useState(AppState.currentState === 'active');

  useEffect(() => {
    let mounted = true;
    let preferenceChanged = false;
    const preference = AccessibilityInfo.addEventListener('reduceMotionChanged', value => {
      preferenceChanged = true;
      setReducedMotion(value);
    });
    void AccessibilityInfo.isReduceMotionEnabled().then(value => {
      if (mounted && !preferenceChanged) setReducedMotion(value);
    }).catch(() => { /* Keep the accessible, still default if querying fails. */ });
    const lifecycle = AppState.addEventListener('change', state => {
      setAppActive(state === 'active');
    });
    return () => {
      mounted = false;
      preference.remove();
      lifecycle.remove();
    };
  }, []);

  return { reducedMotion, appActive };
}
