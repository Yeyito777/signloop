import { useCallback, useRef } from 'react';
import { router, useFocusEffect } from 'expo-router';
import { ScrollView, StyleSheet, View, useWindowDimensions } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { GooseAvatar } from '../integrations/GooseAvatar';
import { Button, Copy, IconButton, Wordmark, useReducedMotion } from '../ui/primitives';
import { StageSlot, useSharedStage, type StageSlotHandle } from '../ui/SharedStage';
import { tokens } from '../ui/theme';

export default function Home() {
  const reducedMotion = useReducedMotion();
  const { width, fontScale } = useWindowDimensions();
  // This display headline is already large: preserve whole words as Dynamic Type grows.
  // Body text, captions, and controls continue to use the full system scale.
  const headlineSize = Math.min(80, (width - 48) / (4.75 * Math.max(1, fontScale)));
  const stage = useRef<StageSlotHandle>(null);
  const scroll = useRef<ScrollView>(null);
  const { prepareConversation, homeViewport } = useSharedStage();
  const navigating = useRef(false);
  useFocusEffect(useCallback(() => { navigating.current = false; }, []));
  const start = () => {
    if (navigating.current) return;
    navigating.current = true;
    prepareConversation();
    router.push('/conversation');
  };
  return <SafeAreaView style={styles.screen}>
    <View style={styles.header}><Wordmark /><IconButton icon="settings" label="Voice settings" onPress={() => router.push('/settings')} /></View>
    <ScrollView ref={scroll} onLayout={() => scroll.current?.getNativeScrollRef()?.measureInWindow((_, y, __, h) => { homeViewport.value = { top: y, bottom: y + h }; })} onScroll={() => stage.current?.measure()} scrollEventThrottle={16} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <Copy role="poster" accessibilityRole="header" style={[styles.title, { fontSize: headlineSize, lineHeight: headlineSize * tokens.type.poster.lineHeight / tokens.type.poster.size }]}>You were{ '\n' }saying?</Copy>
      <StageSlot ref={stage} owner="home" Renderer={GooseAvatar} mode="idle" emotion="neutral" reducedMotion={reducedMotion} style={[styles.stage, { minHeight: width * 0.95 }]} />
    </ScrollView>
    <View style={styles.actions}>
      <Button icon="arrow" variant="ink" style={styles.start} onPress={start}>Start conversation</Button>
    </View>
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 12, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  content: { paddingHorizontal: 24, paddingTop: 16, paddingBottom: 8, flexGrow: 1 },
  title: { paddingBottom: 12 },
  stage: { flex: 1, marginHorizontal: -16 },
  start: { minHeight: 64, justifyContent: 'space-between', paddingHorizontal: 24 },
  actions: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 14 },
});
