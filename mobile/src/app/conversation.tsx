import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { router, useLocalSearchParams } from 'expo-router';
import { BackHandler, ScrollView, StyleSheet, View, useWindowDimensions } from 'react-native';
import Animated from 'react-native-reanimated';
import { SafeAreaView } from 'react-native-safe-area-context';
import { demoKit } from '../integrations/demo';
import { cameraKit } from '../integrations/nativeCamera';
import type { AvatarMode } from '../integrations/contracts';
import { CameraGuidance } from '../session/CameraGuidance';
import { CaptionPanel } from '../session/CaptionPanel';
import { ConversationSheets } from '../session/ConversationSheets';
import { useConversation } from '../session/useConversation';
import { conversationLayout } from '../session/conversationLayout';
import { Button, Copy, Icon, IconButton, Wordmark, Touch } from '../ui/primitives';
import { useMotion } from '../ui/motion';
import { StageSlot, useConversationEntrance } from '../ui/SharedStage';
import { tokens } from '../ui/theme';
import { useIsFocused } from '@react-navigation/native';
import type { DetectionEvent } from '../../modules/signloop-camera';
import type { DetectionSettings } from '../session/ConversationSheets';

export default function Conversation() {
  const { demo } = useLocalSearchParams<{ demo?: string }>();
  const kit = demo === '1' ? demoKit : cameraKit;
  const focused = useIsFocused();
  const [detection, setDetection] = useState<DetectionEvent | null>(null);
  const [detectionSettings, setDetectionSettings] = useState<DetectionSettings>({
    showSkeleton: true, showPose: true, trackFace: false, showScores: false,
  });
  const { state: liveState, dispatch, captureActive, onFraming, onTranslation } = useConversation(kit);
  useEffect(() => { if (!focused) dispatch({ type: 'pause' }); }, [focused]);
  const { reduced, enter, exit } = useMotion();
  const entrance = useConversationEntrance();
  const { height, fontScale } = useWindowDimensions();
  const [availableHeight, setAvailableHeight] = useState(height - 160);
  const regions = conversationLayout(availableHeight, fontScale);
  const uncovered = useRef(liveState);
  useLayoutEffect(() => { if (!liveState.sheet) uncovered.current = liveState; }, [liveState]);
  const state = liveState.sheet ? uncovered.current : liveState;
  const Camera = kit.Camera;
  const phrase = state.phrases.at(-1);
  const speakingPhrase = state.speech ? state.phrases.find(item => item.id === state.speech?.phraseId) : undefined;
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
    <View onLayout={event => setAvailableHeight(Math.max(0, event.nativeEvent.layout.height - 36))} style={styles.split} pointerEvents={covered ? 'none' : 'auto'} accessibilityElementsHidden={covered} importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}>
      <Animated.View style={[styles.camera, { height: regions.camera }, entrance.camera]}>
        <Camera active={captureActive && focused} captureId={liveState.captureId} framing={liveState.framing}
          recognitionMode={liveState.recognitionMode} detectionSettings={detectionSettings} onDetection={setDetection}
          onFraming={onFraming} onTranslation={onTranslation} style={StyleSheet.absoluteFill} />
        {!paused && <CameraGuidance framing={state.framing} active={captureActive} mode={kit.mode} dispatch={dispatch} demo={kit.mode === 'demo'} />}
        {paused && <Animated.View entering={enter} exiting={exit} style={styles.pauseLayer}><ScrollView contentContainerStyle={styles.pauseContent}>
          <Icon name="pause" size={28} /><Copy role="sheetTitle">Paused</Copy><Copy>Camera and voice are paused.</Copy>
          <Button variant="secondary" icon="play" onPress={() => dispatch({ type: 'resume' })}>Resume</Button>
        </ScrollView></Animated.View>}
        {kit.mode === 'demo' && !paused && <Touch accessibilityRole="button" accessibilityLabel="Demo camera. Preview different states" onPress={() => dispatch({ type: 'open-sheet', sheet: 'demo' })} style={styles.demoTag}>
          <Icon name="info" size={16} /><Copy role="label">Demo · try states</Copy>
        </Touch>}
      </Animated.View>
      <StageSlot owner="conversation" Renderer={kit.Avatar} mode={mode} emotion={speakingPhrase?.emotion ?? phrase?.emotion ?? 'neutral'} reducedMotion={reduced || paused || covered} style={[styles.stage, { height: regions.goose }]} />
      <Animated.View style={[styles.captionRegion, { height: regions.caption }, entrance.caption]}>
        <CaptionPanel state={state} mode={kit.mode} dispatch={dispatch}
          detection={detection} showScores={detectionSettings.showScores} />
      </Animated.View>
    </View>
    <ConversationSheets state={liveState} dispatch={dispatch} demo={kit.mode === 'demo'} onEnd={() => router.dismissTo('/')}
      detectionSettings={detectionSettings} setDetectionSettings={setDetectionSettings} />
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 12, minHeight: 56, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  split: { flex: 1, paddingHorizontal: 16, paddingBottom: 12, gap: 12 },
  camera: { borderRadius: 28, overflow: 'hidden', backgroundColor: tokens.color.blue },
  stage: { width: '100%' },
  captionRegion: { paddingHorizontal: 4 },
  demoTag: { position: 'absolute', bottom: 8, left: 12, minHeight: 44, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 14, backgroundColor: tokens.color.paper },
  pauseLayer: { ...StyleSheet.absoluteFillObject, backgroundColor: '#FFFCF0ED' },
  pauseContent: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', padding: 20, gap: 12 },
});
