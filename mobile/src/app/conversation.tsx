import { useEffect, useLayoutEffect, useRef } from 'react';
import { router, useLocalSearchParams } from 'expo-router';
import { BackHandler, StyleSheet, View } from 'react-native';
import Animated from 'react-native-reanimated';
import { SafeAreaView } from 'react-native-safe-area-context';
import { demoKit } from '../integrations/demo';
import { cameraKit } from '../integrations/nativeCamera';
import type { AvatarMode } from '../integrations/contracts';
import { CameraGuidance } from '../session/CameraGuidance';
import { CaptionPanel } from '../session/CaptionPanel';
import { ConversationSheets } from '../session/ConversationSheets';
import { useConversation } from '../session/useConversation';
import { Button, Copy, Icon, IconButton, Wordmark, Touch } from '../ui/primitives';
import { useMotion } from '../ui/motion';
import { StageSlot, useConversationEntrance } from '../ui/SharedStage';
import { tokens } from '../ui/theme';

export default function Conversation() {
  const { demo } = useLocalSearchParams<{ demo?: string }>();
  const kit = demo === '1' ? demoKit : cameraKit;
  const { state: liveState, dispatch, captureActive, onFraming, onTranslation } = useConversation(kit);
  const { reduced, enter, exit } = useMotion();
  const entrance = useConversationEntrance();
  const uncovered = useRef(liveState);
  useLayoutEffect(() => { if (!liveState.sheet) uncovered.current = liveState; }, [liveState]);
  const state = liveState.sheet ? uncovered.current : liveState;
  const Camera = kit.Camera;
  const phrase = state.phrases.at(-1);
  const paused = state.paused;
  const covered = !!liveState.sheet;
  const openEnd = () => dispatch({ type: 'open-sheet', sheet: 'end' });
  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => { dispatch({ type: 'open-sheet', sheet: 'end' }); return true; });
    return () => subscription.remove();
  }, []);
  const mode: AvatarMode = paused || covered || state.framing.startsWith('camera-') ? 'idle'
    : state.speech?.started ? 'speaking' : state.speech || state.phase === 'thinking' ? 'thinking' : 'listening';
  return <SafeAreaView style={styles.screen}>
    <View style={styles.header} pointerEvents={covered ? 'none' : 'auto'} accessibilityElementsHidden={covered} importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}>
      <IconButton icon="back" label="End conversation" onPress={openEnd} />
      <Wordmark />
      <IconButton icon="more" label="Conversation menu" onPress={() => dispatch({ type: 'open-sheet', sheet: 'menu' })} />
    </View>
    <View style={styles.split} pointerEvents={covered ? 'none' : 'auto'} accessibilityElementsHidden={covered} importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}>
      <Animated.View style={[styles.camera, entrance.camera]}>
        <Camera active={captureActive} captureId={liveState.captureId} framing={liveState.framing} onFraming={onFraming} onTranslation={onTranslation} style={StyleSheet.absoluteFill} />
        {!paused && <CameraGuidance framing={state.framing} active={captureActive} mode={kit.mode} dispatch={dispatch} demo={kit.mode === 'demo'} />}
        {paused && <Animated.View entering={enter} exiting={exit} style={styles.pauseLayer}>
          <Icon name="pause" size={28} /><Copy role="sheetTitle">Paused</Copy><Copy>Camera and voice are paused.</Copy>
          <Button variant="secondary" icon="play" onPress={() => dispatch({ type: 'resume' })}>Resume</Button>
        </Animated.View>}
        {kit.mode === 'demo' && !paused && <Touch accessibilityRole="button" accessibilityLabel="Demo camera. Preview different states" onPress={() => dispatch({ type: 'open-sheet', sheet: 'demo' })} style={styles.demoTag}>
          <Icon name="info" size={16} /><Copy role="label">Demo · try states</Copy>
        </Touch>}
      </Animated.View>
      <View style={styles.companion}>
        <StageSlot owner="conversation" Renderer={kit.Avatar} mode={mode} emotion={phrase?.emotion ?? 'neutral'} reducedMotion={reduced || paused || covered} style={styles.stage} />
        <Animated.View style={[styles.captionRegion, entrance.caption]}>
          <CaptionPanel state={state} mode={kit.mode} dispatch={dispatch} />
        </Animated.View>
      </View>
    </View>
    <ConversationSheets state={liveState} dispatch={dispatch} demo={kit.mode === 'demo'} onEnd={() => router.dismissTo('/')} />
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 12, minHeight: 56, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  split: { flex: 1, paddingHorizontal: 16, paddingBottom: 12, gap: 12 },
  camera: { flex: 1, borderRadius: 28, overflow: 'hidden', backgroundColor: tokens.color.blue, borderWidth: 1.5, borderColor: tokens.color.ink },
  companion: { flex: 1, paddingHorizontal: 4, gap: 12, justifyContent: 'flex-end' },
  stage: { flex: 1, minHeight: 48, maxHeight: 176 },
  captionRegion: { flexShrink: 1, maxHeight: '82%' },
  demoTag: { position: 'absolute', bottom: 8, left: 12, minHeight: 44, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 14, backgroundColor: tokens.color.paper },
  pauseLayer: { ...StyleSheet.absoluteFillObject, backgroundColor: '#FFFCF0ED', alignItems: 'center', justifyContent: 'center', padding: 20, gap: 12 },
});
