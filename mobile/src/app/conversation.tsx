import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
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
import { conversationFocus, conversationLayout } from '../session/conversationLayout';
import { Button, Copy, Icon, IconButton, Wordmark, Touch } from '../ui/primitives';
import { useMotion } from '../ui/motion';
import { StageSlot, useConversationEntrance } from '../ui/SharedStage';
import { tokens } from '../ui/theme';
import { conversationEmotion, moodPresentation } from '../integrations/expression';
import { useIsFocused } from '@react-navigation/native';
import type { DetectionSettings } from '../session/ConversationSheets';
import { useGooseEmote } from '../../../goose/src/hooks/useGooseEmote';
import { GoosePressTarget } from '../../../goose/src/components/GoosePressTarget';

function isDemo(value: string | string[] | undefined) {
  return (Array.isArray(value) ? value[0] : value) === '1';
}

export default function Conversation() {
  const { demo } = useLocalSearchParams<{ demo?: string | string[] }>();
  const kit = isDemo(demo) ? demoKit : cameraKit;
  const focused = useIsFocused();
  const [detectionSettings, setDetectionSettings] = useState<DetectionSettings>({
    showSkeleton: true, showPose: true, trackFace: true, showScores: false,
  });
  const { state: liveState, dispatch, captureActive, onFraming, onTranslation, onExpression } = useConversation(kit);
  useEffect(() => { if (!focused) dispatch({ type: 'pause' }); }, [focused]);
  const { reduced, enter, exit, layout, sceneLayout } = useMotion();
  const dance = useGooseEmote();
  useFocusEffect(useCallback(() => dance.stop, [dance.stop]));
  const entrance = useConversationEntrance();
  const { width, height, fontScale } = useWindowDimensions();
  const [available, setAvailable] = useState({ height: height - 160, width });
  const uncovered = useRef(liveState);
  useLayoutEffect(() => { if (!liveState.sheet) uncovered.current = liveState; }, [liveState]);
  const state = liveState.sheet ? uncovered.current : liveState;
  const Camera = kit.Camera;
  const paused = state.paused;
  const covered = !!liveState.sheet;
  const openEnd = () => dispatch({ type: 'open-sheet', sheet: 'end' });
  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => { dispatch({ type: 'open-sheet', sheet: 'end' }); return true; });
    return () => subscription.remove();
  }, []);
  const mode: AvatarMode = paused || covered || state.framing.startsWith('camera-') ? 'idle'
    : state.speech?.started ? 'speaking' : state.speech || state.phase === 'thinking' ? 'thinking' : 'listening';
  const danceDisabled = reduced || paused || covered || mode === 'thinking' || mode === 'speaking';
  useEffect(() => { if (danceDisabled) dance.stop(); }, [danceDisabled, dance.stop]);
  const focus = conversationFocus(mode, reduced);
  const regions = conversationLayout(available.height, fontScale, focus, available.width);
  const regionLayout = focus === 'speaking' ? sceneLayout : layout;
  const mood = moodPresentation(liveState);
  return <SafeAreaView style={styles.screen}>
    <View style={styles.header} pointerEvents={covered ? 'none' : 'auto'} accessibilityElementsHidden={covered} importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}>
      <IconButton icon="back" label="End conversation" onPress={openEnd} />
      <Wordmark />
      <IconButton icon="more" label="Conversation menu" onPress={() => dispatch({ type: 'open-sheet', sheet: 'menu' })} />
    </View>
    <View onLayout={event => setAvailable({
      height: Math.max(0, event.nativeEvent.layout.height - 36),
      width: event.nativeEvent.layout.width,
    })} style={styles.split} pointerEvents={covered ? 'none' : 'auto'} accessibilityElementsHidden={covered} importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}>
      <Animated.View layout={regionLayout} style={[styles.camera, { height: regions.camera }, entrance.camera]}>
        <Camera active={captureActive && focused} captureId={liveState.captureId} framing={liveState.framing}
          recognitionMode="signs" detectionSettings={detectionSettings}
          onFraming={onFraming} onTranslation={onTranslation} onExpression={onExpression} style={StyleSheet.absoluteFill} />
        {!paused && <CameraGuidance framing={state.framing} active={captureActive} mode={kit.mode} dispatch={dispatch} demo={kit.mode === 'demo'} />}
        {paused && <Animated.View entering={enter} exiting={exit} style={styles.pauseLayer}><ScrollView contentContainerStyle={styles.pauseContent}>
          <Icon name="pause" size={28} /><Copy role="sheetTitle">Paused</Copy><Copy>Camera and voice are paused.</Copy>
          <Button variant="secondary" icon="play" onPress={() => dispatch({ type: 'resume' })}>Resume</Button>
        </ScrollView></Animated.View>}
        {kit.mode === 'demo' && !paused && <Touch accessibilityRole="button" accessibilityLabel="Demo camera. Preview different states" onPress={() => dispatch({ type: 'open-sheet', sheet: 'demo' })} style={styles.demoTag}>
          <Icon name="info" size={16} /><Copy role="label">Demo · try states</Copy>
        </Touch>}
      </Animated.View>
      <Animated.View layout={regionLayout} style={[styles.stage, { height: regions.goose, marginTop: regions.clearance }]}>
        <StageSlot owner="conversation" Renderer={kit.Avatar} mode={mode} emotion={conversationEmotion(liveState)} reducedMotion={reduced || paused || covered} emote={dance.request} onEmoteEnd={dance.onEmoteEnd} style={styles.stageSlot}>
          <GoosePressTarget onPress={dance.request ? dance.stop : dance.play} playing={!!dance.request} disabled={danceDisabled} />
        </StageSlot>
        <View pointerEvents="none" style={styles.mood} accessibilityLabel={`Goose mood: ${mood.mood}. ${mood.detail}`}>
          <Copy role="label">{mood.mood}</Copy>
          <Copy role="supporting" style={styles.moodDetail}>{mood.detail}</Copy>
        </View>
      </Animated.View>
      <Animated.View layout={regionLayout} style={[styles.captionRegion, { height: regions.caption }, entrance.caption]}>
        <CaptionPanel state={state} mode={kit.mode} dispatch={dispatch} />
      </Animated.View>
    </View>
    <ConversationSheets state={liveState} dispatch={dispatch} demo={kit.mode === 'demo'} onEnd={() => router.dismissTo('/')}
      detectionSettings={detectionSettings} setDetectionSettings={setDetectionSettings} />
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 12, minHeight: 56, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  split: { flex: 1, paddingBottom: 12, gap: 12 },
  camera: { borderRadius: 0, overflow: 'hidden', backgroundColor: tokens.color.blue },
  stage: { width: '100%', overflow: 'visible', paddingHorizontal: 16 },
  stageSlot: { flex: 1, width: '100%' },
  mood: { position: 'absolute', top: 0, right: 16, maxWidth: '72%', alignItems: 'flex-end', paddingHorizontal: 10, paddingVertical: 6, borderRadius: 12, backgroundColor: tokens.color.paper },
  moodDetail: { color: tokens.color.muted, textAlign: 'right' },
  captionRegion: { paddingHorizontal: 20 },
  demoTag: { position: 'absolute', bottom: 8, left: 12, minHeight: 44, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 14, backgroundColor: tokens.color.paper },
  pauseLayer: { ...StyleSheet.absoluteFillObject, backgroundColor: '#FFFCF0ED' },
  pauseContent: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', padding: 20, gap: 12 },
});
