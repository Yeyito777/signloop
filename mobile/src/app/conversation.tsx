import { useEffect } from 'react';
import { router, useLocalSearchParams } from 'expo-router';
import { BackHandler, Linking, Pressable, ScrollView, StyleSheet, View, useWindowDimensions } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { demoKit } from '../integrations/demo';
import { cameraKit } from '../integrations/nativeCamera';
import type { AvatarMode, Framing } from '../integrations/contracts';
import { ConversationSheets } from '../session/ConversationSheets';
import { useConversation } from '../session/useConversation';
import { Button, Copy, Icon, IconButton, Wordmark, useReducedMotion, type IconName } from '../ui/primitives';
import { tokens } from '../ui/theme';

const framingCopy: Record<Framing, { title: string; hint: string; icon: IconName }> = {
  finding: { title: 'Find your frame', hint: 'Keep your face and both hands in view.', icon: 'frame' },
  ready: { title: 'You’re in view', hint: 'Start signing. Your words will appear here.', icon: 'check' },
  'hands-missing': { title: 'Bring your hands into view', hint: 'Keep both hands inside the frame.', icon: 'hand' },
  'too-close': { title: 'Move a little farther back', hint: 'Give your hands a little more room.', icon: 'frame' },
  'too-far': { title: 'Move a little closer', hint: 'Make sure your face and hands are clearly visible.', icon: 'frame' },
  'low-light': { title: 'Find a little more light', hint: 'Try facing a window or a light.', icon: 'sun' },
  away: { title: 'Step into the frame', hint: 'Come back into view when you’re ready.', icon: 'frame' },
  'camera-denied': { title: 'Camera access needed', hint: 'Allow camera access in Settings, then return and tap Resume.', icon: 'frame' },
  'camera-unavailable': { title: 'Camera unavailable here', hint: 'Open the development build on an iPhone to try hand tracking.', icon: 'frame' },
  'camera-error': { title: 'Camera couldn’t start', hint: 'Try starting the camera again.', icon: 'frame' },
};

export default function Conversation() {
  // Swap this kit at the integration boundary. Screen layout does not depend on the renderer or scanner.
  const { demo } = useLocalSearchParams<{ demo?: string }>();
  const kit = demo === '1' ? demoKit : cameraKit;
  const { state, dispatch, captureActive, onFraming } = useConversation(kit);
  const reducedMotion = useReducedMotion();
  const { fontScale } = useWindowDimensions();
  const Camera = kit.Camera;
  const Avatar = kit.Avatar;
  const phrase = state.phrases.at(-1);
  const paused = state.paused || !!state.sheet;
  const framing = kit.mode === 'camera' && state.framing === 'ready'
    ? { title: 'Hand detected', hint: 'Hand tracking is working. Translation and voice are coming next.', icon: 'check' as const }
    : kit.mode === 'camera' && state.framing === 'finding'
      ? { title: 'Finding your hands', hint: 'Bring your hands into the camera preview.', icon: 'frame' as const }
      : framingCopy[state.framing];
  const issue = state.framing !== 'finding' && state.framing !== 'ready';
  const cameraBlocked = state.framing.startsWith('camera-');
  const openEnd = () => dispatch({ type: 'open-sheet', sheet: 'end' });

  useEffect(() => {
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      dispatch({ type: 'open-sheet', sheet: 'end' }); return true;
    });
    return () => subscription.remove();
  }, []);

  let heading = phrase ? 'Your last phrase' : 'Ready when you are';
  let caption = phrase?.text ?? framing.hint;
  let label = phrase ? kit.mode === 'demo' ? 'Sample caption' : 'English' : '';
  let mode: AvatarMode = 'listening';
  if (state.framing === 'finding' && !phrase) heading = 'Let’s find your frame';
  if (issue) { heading = 'A little adjustment'; caption = framing.hint; label = ''; }
  if (kit.mode === 'camera' && state.framing === 'ready') heading = 'You’re in view';
  if (cameraBlocked) { heading = 'Let’s get you connected'; mode = 'idle'; }
  if (state.phase === 'signing') { heading = 'Reading your signs'; caption = state.draft; label = 'Draft'; }
  if (state.phase === 'thinking') { heading = 'Putting it together'; caption = state.draft || 'One moment…'; label = 'Translating'; mode = 'thinking'; }
  if (state.speech) { heading = kit.mode === 'demo' ? 'Voice preview' : 'Goose is speaking'; mode = 'speaking'; }
  if (state.phase === 'uncertain') { heading = 'One more time?'; caption = 'Could you sign that again?'; label = 'Not spoken'; }
  if (state.phase === 'offline') { heading = 'We lost connection'; caption = phrase?.text ?? 'Your captions will return when we reconnect.'; label = phrase ? 'Last phrase' : ''; }
  if (state.phase === 'voice-error') { heading = 'Voice isn’t available'; label = 'Not spoken · read this instead'; }
  if (paused) { heading = 'Take your time'; caption = phrase?.text ?? 'Pick up where you left off.'; label = phrase ? 'Last phrase' : ''; mode = 'idle'; }
  const hasTools = !!phrase && !issue && !['signing', 'thinking', 'uncertain'].includes(state.phase);

  return <SafeAreaView style={styles.screen}>
    <View style={styles.header}>
      <IconButton icon="back" label="End conversation" onPress={openEnd} />
      <Wordmark />
      <IconButton icon="more" label="Conversation menu" onPress={() => dispatch({ type: 'open-sheet', sheet: 'menu' })} />
    </View>
    <View style={styles.split}>
      <View style={styles.camera}>
        <Camera active={captureActive} captureId={state.captureId} framing={state.framing} onFraming={onFraming} style={StyleSheet.absoluteFill} />
        {!paused && <>
          {cameraBlocked && <View pointerEvents="none" style={styles.cameraNotice}><Icon name="frame" size={44} /></View>}
          {!cameraBlocked && <View pointerEvents="none" style={[styles.guide, { borderColor: state.framing === 'ready' ? tokens.color.successSurface : tokens.color.paper }]} />}
          <View style={styles.cameraTop}>
            <View style={[styles.feedback, { backgroundColor: issue ? tokens.color.cautionSurface : state.framing === 'ready' ? tokens.color.successSurface : tokens.color.paper }]}>
              <Icon name={state.phase === 'offline' ? 'offline' : framing.icon} size={20} /><Copy role="label" style={{ flexShrink: 1 }}>{state.phase === 'offline' ? 'Translation paused' : framing.title}</Copy>
            </View>
            <IconButton filled icon="pause" label="Pause camera and voice" onPress={() => dispatch({ type: 'pause' })} />
          </View>
        </>}
        {paused && <View style={styles.pauseLayer}>
          <Icon name="pause" size={28} /><Copy role="sheetTitle">Paused</Copy><Copy>Camera and voice are paused.</Copy>
          {!state.sheet && <Button variant="secondary" icon="play" onPress={() => dispatch({ type: 'resume' })}>Resume</Button>}
        </View>}
        {kit.mode === 'demo' && !paused && <Pressable accessibilityRole="button" accessibilityLabel="Demo camera. Preview different states" onPress={() => dispatch({ type: 'open-sheet', sheet: 'demo' })} style={styles.demoTag}>
          <Icon name="info" size={16} /><Copy role="label">Demo · try states</Copy>
        </Pressable>}
      </View>
      <View style={styles.companion}>
        <View style={styles.companionHeader}><Copy role="status" accessibilityLiveRegion="polite" style={styles.center}>{heading}</Copy></View>
        <Avatar mode={mode} emotion={phrase?.emotion ?? 'neutral'} reducedMotion={reducedMotion || paused} style={[styles.goose, fontScale > 1.3 && { maxHeight: 84 }]} />
        <View style={styles.bubble}>
          {!!label && <Copy role="label" style={styles.captionLabel}>{label}</Copy>}
          <ScrollView style={styles.captionScroll} contentContainerStyle={styles.captionContent} showsVerticalScrollIndicator>
            <Copy role="caption" selectable accessibilityLiveRegion="polite">{caption}</Copy>
          </ScrollView>
          {hasTools && <View style={styles.captionTools}>
            <Copy role="supporting" style={styles.captionMeta}>{state.muted ? 'Voice off' : kit.mode === 'demo' ? 'Silent preview' : state.speech ? 'Speaking' : phrase.status === 'played' ? 'Spoken' : 'Caption ready'}</Copy>
            <IconButton icon="edit" label="Correct this phrase" onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
            <IconButton icon="repeat" label="Replay this phrase" disabled={state.muted || state.paused} onPress={() => dispatch({ type: 'replay' })} />
          </View>}
          {state.framing === 'camera-denied' && <Button variant="plain" onPress={() => {
            dispatch({ type: 'pause' });
            void Linking.openSettings();
          }}>Open Settings</Button>}
          {state.framing === 'camera-unavailable' && <Button variant="plain" onPress={() => router.replace('/conversation?demo=1')}>Try the UI demo</Button>}
          {(!cameraBlocked && issue || state.framing === 'camera-error' || state.phase === 'uncertain' || state.phase === 'offline') && <Button variant="plain" icon="repeat" onPress={() => dispatch({ type: 'retry' })}>{state.phase === 'offline' ? 'Try connection again' : kit.mode === 'demo' ? 'Try sample again' : 'Try again'}</Button>}
          {state.phase === 'voice-error' && <Button variant="plain" icon="volume" onPress={() => dispatch({ type: 'replay' })}>Try voice again</Button>}
        </View>
      </View>
    </View>
    <ConversationSheets state={state} dispatch={dispatch} demo={kit.mode === 'demo'} onEnd={() => router.dismissTo('/')} />
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 12, minHeight: 56, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  split: { flex: 1, paddingHorizontal: 16, paddingBottom: 12, gap: 12 },
  camera: { flex: 1, borderRadius: 28, overflow: 'hidden', backgroundColor: tokens.color.blue, borderWidth: 1.5, borderColor: tokens.color.ink },
  cameraNotice: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center', backgroundColor: tokens.color.blue },
  guide: { position: 'absolute', top: 76, left: 28, right: 28, bottom: 24, borderWidth: 1.5, borderRadius: 24, borderStyle: 'dashed' },
  cameraTop: { position: 'absolute', top: 12, left: 12, right: 12, flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 },
  feedback: { minHeight: 44, borderRadius: 14, paddingVertical: 8, paddingHorizontal: 10, flexDirection: 'row', alignItems: 'center', gap: 8, flexShrink: 1 },
  demoTag: { position: 'absolute', bottom: 8, left: 12, minHeight: 44, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 6, borderRadius: 14, backgroundColor: tokens.color.paper },
  pauseLayer: { ...StyleSheet.absoluteFillObject, backgroundColor: '#FFFCF0ED', alignItems: 'center', justifyContent: 'center', padding: 20, gap: 12 },
  companion: { flex: 1, alignItems: 'stretch', paddingHorizontal: 4, gap: 4 },
  companionHeader: { minHeight: 28, justifyContent: 'center' },
  center: { textAlign: 'center' },
  goose: { flex: 1, minHeight: 44, maxHeight: 180 },
  bubble: { flexShrink: 1, minHeight: 84, backgroundColor: tokens.color.paper, borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 20, borderTopLeftRadius: 4, paddingHorizontal: 16, paddingTop: 12, paddingBottom: 8, boxShadow: `0px 4px 0px ${tokens.color.captionShadow}` },
  captionLabel: { color: tokens.color.muted, marginBottom: 6 },
  captionScroll: { flexShrink: 1 },
  captionContent: { paddingBottom: 8 },
  captionTools: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  captionMeta: { color: tokens.color.muted, flex: 1 },
});
