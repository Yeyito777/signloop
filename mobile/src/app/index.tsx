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
  const { height } = useWindowDimensions();
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
      <Copy role="hero" accessibilityRole="header" style={styles.title}>Ready when{ '\n' }you are.</Copy>
      <StageSlot ref={stage} owner="home" Renderer={GooseAvatar} mode="idle" emotion="neutral" reducedMotion={reducedMotion} style={[styles.stage, { minHeight: height < 750 ? 200 : 270 }]} />
      <Copy role="sectionTitle" style={styles.description}>Try the ILY handshape.{ '\n' }Confirm it. Let your goose speak.</Copy>
      <Copy role="supporting" style={{ textAlign: 'center' }}>Experimental, limited-vocabulary preview. Not full ASL translation.</Copy>
    </ScrollView>
    <View style={styles.actions}>
      <Button icon="arrow" onPress={start}>Start conversation</Button>
      <Button variant="plain" onPress={() => router.push('/conversation?demo=1')}>Preview sample conversation</Button>
    </View>
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 12, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  content: { paddingHorizontal: 24, paddingTop: 28, paddingBottom: 20, flexGrow: 1 },
  title: { fontSize: 48, lineHeight: 51 },
  stage: { flex: 1, alignItems: 'center', justifyContent: 'center', marginVertical: 12 },
  description: { textAlign: 'center', fontSize: 23, lineHeight: 30 },
  actions: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 14 },
});
