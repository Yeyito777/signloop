import { useEffect, type ReactNode } from 'react';
import { KeyboardAvoidingView, Modal, Platform, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Copy, IconButton, useReducedMotion } from './primitives';
import { tokens } from './theme';

export function Sheet({ title, children, onClose, visible, onDismiss }: { title: string; children: ReactNode; onClose: () => void; visible: boolean; onDismiss: () => void }) {
  const insets = useSafeAreaInsets();
  const reduced = useReducedMotion();
  // React Native exposes onDismiss on iOS; complete the retained-sheet lifecycle on Android too.
  useEffect(() => {
    if (visible || Platform.OS === 'ios') return;
    const timer = setTimeout(onDismiss, reduced ? 0 : 350);
    return () => clearTimeout(timer);
  }, [visible, reduced, onDismiss]);
  return <Modal visible={visible} transparent animationType={reduced ? 'none' : 'slide'} onDismiss={onDismiss} onRequestClose={onClose} statusBarTranslucent>
    <KeyboardAvoidingView style={styles.backdrop} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <Pressable accessibilityLabel="Dismiss sheet" accessibilityRole="button" style={StyleSheet.absoluteFill} onPress={onClose} />
      <View style={[styles.sheet, { paddingBottom: Math.max(insets.bottom, 20) }]} accessibilityViewIsModal>
        <View style={styles.handle} />
        <View style={styles.heading}><Copy role="sheetTitle" accessibilityRole="header" style={styles.title}>{title}</Copy><IconButton icon="close" label={`Close ${title.toLowerCase()}`} onPress={onClose} /></View>
        <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>{children}</ScrollView>
      </View>
    </KeyboardAvoidingView>
  </Modal>;
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, justifyContent: 'flex-end', backgroundColor: '#34241E66' },
  sheet: { backgroundColor: tokens.color.paper, borderTopLeftRadius: 28, borderTopRightRadius: 28, maxHeight: '88%', paddingTop: 12 },
  handle: { width: 38, height: 4, borderRadius: 2, backgroundColor: tokens.color.line, alignSelf: 'center', marginBottom: 12 },
  heading: { flexDirection: 'row', paddingLeft: 24, paddingRight: 16, alignItems: 'center', marginBottom: 12, gap: 8 },
  title: { flex: 1 },
  content: { paddingHorizontal: 24, paddingTop: 4, paddingBottom: 12, gap: 16 },
});
