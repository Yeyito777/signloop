import { useCallback, useEffect, useRef, type ReactNode } from 'react';
import { BackHandler, Pressable, StyleSheet, View, useWindowDimensions } from 'react-native';
import { BottomSheetBackdrop, BottomSheetModal, BottomSheetScrollView, useBottomSheetSpringConfigs, type BottomSheetBackdropProps, type BottomSheetBackgroundProps } from '@gorhom/bottom-sheet';
import Animated, { ReduceMotion } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Copy, IconButton, InverseSurface } from './primitives';
import { motion, useMotion } from './motion';
import { tokens } from './theme';

/** One persistent surface: content changes inside it, while pan, backdrop and keyboard stay coordinated. */
export function Sheet({ title, contentKey, children, onClose, visible, closing, onDismiss }: {
  title: string; contentKey: string; children: ReactNode; onClose: () => void;
  visible: boolean; closing: boolean; onDismiss: () => void;
}) {
  const ref = useRef<BottomSheetModal>(null);
  const insets = useSafeAreaInsets();
  const { height } = useWindowDimensions();
  const { enter, reduced } = useMotion();
  const animationConfigs = useBottomSheetSpringConfigs(motion.sheetSpring);
  useEffect(() => { if (visible) ref.current?.present(); }, [visible]);
  useEffect(() => { if (closing) ref.current?.dismiss(); }, [closing]);
  useEffect(() => {
    if (!visible) return;
    const listener = BackHandler.addEventListener('hardwareBackPress', () => { onClose(); return true; });
    return () => listener.remove();
  }, [visible, onClose]);
  const backdrop = useCallback((props: BottomSheetBackdropProps) => <BottomSheetBackdrop {...props}
    appearsOnIndex={0} disappearsOnIndex={-1} opacity={0.28} pressBehavior="none" accessible={false}>
    <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" onPress={onClose}
      accessibilityLabel="Close sheet" accessibilityHint="Return to the conversation" />
  </BottomSheetBackdrop>, [onClose]);
  return <BottomSheetModal ref={ref} accessible={false} enablePanDownToClose enableDynamicSizing
    topInset={insets.top + 12} maxDynamicContentSize={height - insets.top - 28}
    animationConfigs={animationConfigs} overrideReduceMotion={reduced ? ReduceMotion.Always : ReduceMotion.Never}
    keyboardBehavior="interactive" keyboardBlurBehavior="restore" enableBlurKeyboardOnGesture
    android_keyboardInputMode="adjustResize" backdropComponent={backdrop}
    backgroundComponent={SheetBackground} handleComponent={SheetHandle}
    onAnimate={(_, toIndex) => { if (toIndex === -1) onClose(); }} onDismiss={onDismiss}>
    <BottomSheetScrollView key={contentKey} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}
      contentContainerStyle={{ paddingBottom: Math.max(insets.bottom, 20) + 12 }}>
      <InverseSurface><Animated.View entering={enter} pointerEvents={closing ? 'none' : 'auto'} accessibilityViewIsModal onAccessibilityEscape={onClose}>
        <View style={styles.heading}>
          <Copy role="sheetTitle" accessibilityRole="header" style={styles.title}>{title}</Copy>
          <IconButton icon="close" label={`Close ${title.toLowerCase()}`} onPress={onClose} />
        </View>
        <View style={styles.content}>{children}</View>
      </Animated.View></InverseSurface>
    </BottomSheetScrollView>
  </BottomSheetModal>;
}

function SheetBackground({ style }: BottomSheetBackgroundProps) {
  return <View pointerEvents="none" accessible={false} style={[style, styles.surface]} />;
}

function SheetHandle() {
  return <View accessible={false} style={styles.handleArea}><View style={styles.handle} /></View>;
}

const styles = StyleSheet.create({
  surface: { backgroundColor: tokens.color.ink, borderRadius: 32 },
  handle: { width: 38, height: 4, borderRadius: 2, backgroundColor: `${tokens.color.paper}66`, alignSelf: 'center' },
  handleArea: { paddingTop: 12, paddingBottom: 16 },
  heading: { flexDirection: 'row', paddingLeft: 24, paddingRight: 16, alignItems: 'center', marginBottom: 12, gap: 8 },
  title: { flex: 1, fontSize: 36, lineHeight: 36, letterSpacing: -1 },
  content: { paddingHorizontal: 24, paddingTop: 4, gap: 16 },
});
