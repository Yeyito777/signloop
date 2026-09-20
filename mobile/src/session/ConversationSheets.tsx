import { useCallback, useRef, useState, type Dispatch, type ReactNode } from 'react';
import { AppState, Keyboard, StyleSheet, View } from 'react-native';
import { BottomSheetTextInput } from '@gorhom/bottom-sheet';
import type { Framing, TranslationEvent } from '../integrations/contracts';
import { Button, Copy, Icon, Touch, type IconName } from '../ui/primitives';
import { Sheet } from '../ui/Sheet';
import { textStyles, tokens } from '../ui/theme';
import type { Action, Session } from './model';
import { Switch } from 'react-native';
import { router } from 'expo-router';
import { MAX_SENTENCE_CHARACTERS, sentenceText } from './sentence';

export type DetectionSettings = { showSkeleton: boolean; showPose: boolean; trackFace: boolean; showScores: boolean };

export function ConversationSheets({ state, dispatch, onEnd, demo, detectionSettings, setDetectionSettings }: {
  state: Session; dispatch: Dispatch<Action>; onEnd: () => void; demo: boolean;
  detectionSettings?: DetectionSettings; setDetectionSettings?: (settings: DetectionSettings) => void;
}) {
  const [closing, setClosing] = useState(false);
  const dismissing = useRef(false);
  const afterDismiss = useRef<(() => void) | null>(null);
  // Keep the session suspended for the whole exit animation, including a dragged dismissal.
  const dismiss = useCallback((action?: () => void) => {
    if (dismissing.current) return;
    dismissing.current = true;
    afterDismiss.current = action ?? (() => dispatch({ type: 'close-sheet' }));
    Keyboard.dismiss();
    setClosing(true);
  }, [dispatch]);
  const close = useCallback(() => dismiss(), [dismiss]);
  const commit: Dispatch<Action> = action => dismiss(() => dispatch(action));
  // Leave capture suspended as the conversation fades away; its route owns session cleanup.
  const end = () => dismiss(onEnd);
  const onDismiss = () => {
    const action = afterDismiss.current;
    afterDismiss.current = null;
    dismissing.current = false;
    setClosing(false);
    if (action) action();
    else dispatch({ type: 'close-sheet' });
    // Backgrounding during dismissal must not restart capture or speech.
    if (AppState.currentState !== 'active') dispatch({ type: 'pause' });
  };
  let title = '';
  let content: ReactNode = null;
  switch (state.sheet) {
    case 'transcript': title = 'This conversation'; content = <>
      <Copy role="supporting" style={styles.muted}>Your phrases stay here until you end this conversation.</Copy>
      {state.phrases.length === 0 ? <View style={styles.empty}><Icon name="transcript" size={32} /><Copy role="sectionTitle">No phrases yet.</Copy><Copy style={styles.center}>Your translated words will appear here.</Copy></View> : state.phrases.map((phrase, i) => <View key={phrase.id} style={styles.phrase}>
        <Copy role="label" style={styles.muted}>{String(i + 1).padStart(2, '0')} · {phrase.original ? 'Corrected' : demo ? 'Sample caption' : phrase.status === 'played' ? 'Spoken' : 'Caption'}</Copy>
        <Copy role="captionLarge" selectable>{phrase.text}</Copy>
        {phrase.original && <View style={styles.original}><Copy role="supporting" style={styles.muted}>Original caption</Copy><Copy>{phrase.original}</Copy></View>}
      </View>)}
      <Button variant="secondary" onPress={close}>Back to conversation</Button>
    </>; break;
    case 'correction': title = 'Make a correction'; content = <><Correction key={state.phrases.at(-1)?.id} state={state} dispatch={commit} /></>; break;
    case 'sentence-editor': title = 'Edit your sentence'; content = <SentenceEditor key={`${state.sentence.id}-${state.sentence.revision}`} state={state} dispatch={commit} />; break;
    case 'menu': title = 'Conversation'; content = <>
      {!demo && <MenuRow icon="frame" label="Detection settings" onPress={() => dispatch({ type: 'open-sheet', sheet: 'detector' })} />}
      {!demo && <MenuRow icon="info" label="Expression lab" onPress={() => dismiss(() => {
        dispatch({ type: 'close-sheet' }); dispatch({ type: 'pause' }); router.push('/expressions');
      })} />}
      <MenuRow icon="transcript" label="View transcript" onPress={() => dispatch({ type: 'open-sheet', sheet: 'transcript' })} />
      <MenuRow icon="edit" label="Correct last phrase" disabled={!state.phrases.length} onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
      <MenuRow icon={state.muted ? 'muted' : 'volume'} label={state.muted ? 'Turn voice on' : 'Turn voice off'} onPress={() => dispatch({ type: 'mute' })} />
      <MenuRow icon="exit" label="End conversation" onPress={() => dispatch({ type: 'open-sheet', sheet: 'end' })} />
    </>; break;
    case 'detector': title = 'On-device detection'; content = <>
      <Copy>11 presentation signs · AURELIO spelling. Guesses need confirmation. Matching uses hands and shoulders; no camera data goes to the backend.</Copy>
      {detectionSettings && ([
        ['showSkeleton', 'Show hand joints'], ['showPose', 'Show upper-body pose'],
        ['trackFace', 'Track facial features (slower)'], ['showScores', 'Show match distances'],
      ] as [keyof DetectionSettings, string][]).map(([key, label]) => <View key={key} style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <Copy style={{ flex: 1 }}>{label}</Copy><Switch accessibilityLabel={label} value={detectionSettings[key]}
          onValueChange={value => setDetectionSettings?.({ ...detectionSettings, [key]: value })} />
      </View>)}
      <Copy role="supporting">Face labels compare a personal profile taught in Expression lab. They are not emotions or ASL meaning. Distances are not probabilities; lower is closer.</Copy>
      <Button onPress={close}>Done</Button>
    </>; break;
    case 'end': title = 'All done for now?'; content = <>
      <Copy>End this conversation? Its transcript and any unfinished sentence will be cleared.</Copy>
      <Button icon="exit" onPress={end}>End conversation</Button>
      <Button variant="plain" onPress={close}>Keep going</Button>
    </>; break;
    case 'demo': title = 'Preview states'; content = <>
      <Copy role="supporting" style={styles.muted}>Sample camera, captions, and silent voice. These controls are only for reviewing the UI.</Copy>
      <MenuRow icon="play" label="Run sample conversation" onPress={() => commit({ type: 'retry' })} />
      {([
        ['hands-missing', 'hand', 'Hands out of view'], ['too-close', 'frame', 'Too close'], ['too-far', 'frame', 'Too far'],
        ['low-light', 'sun', 'Low light'], ['away', 'frame', 'No one in frame'],
      ] as [Framing, IconName, string][]).map(([framing, icon, label]) => <MenuRow key={framing} icon={icon} label={label} onPress={() => commit({ type: 'demo-framing', framing })} />)}
      {([
        ['Goose thinking', 'info', { type: 'thinking' }],
        ['Goose speaking zoom', 'play', { type: 'accepted', id: `zoom-${state.captureId}`, text: 'I’m right here with you.', emotion: 'joy' }],
        ['Goose joy', 'play', { type: 'accepted', id: `joy-${state.captureId}`, text: 'I’m so glad you’re here!', emotion: 'joy' }],
        ['Goose sadness', 'play', { type: 'accepted', id: `sadness-${state.captureId}`, text: 'I wish we had more time together.', emotion: 'sadness' }],
        ['Goose anger', 'play', { type: 'accepted', id: `anger-${state.captureId}`, text: 'That was really frustrating.', emotion: 'anger' }],
        ['Goose fear', 'play', { type: 'accepted', id: `fear-${state.captureId}`, text: 'That gave me a fright!', emotion: 'fear' }],
        ['Goose disgust', 'play', { type: 'accepted', id: `disgust-${state.captureId}`, text: 'That smells awful.', emotion: 'disgust' }],
        ['Uncertain translation', 'info', { type: 'uncertain' }],
        ['Connection lost', 'offline', { type: 'offline' }],
        ['Long caption', 'transcript', { type: 'accepted', id: `long-${state.captureId}`, text: 'Could we find somewhere a little quieter? I would love to hear more about your project, and it would be easier to have a conversation by the window.', emotion: 'neutral' }],
      ] as [string, IconName, TranslationEvent][]).map(([label, icon, event]) => <MenuRow key={label} icon={icon} label={label} onPress={() => commit({ type: 'demo-event', event })} />)}
    </>; break;
  }
  return <Sheet title={title} contentKey={state.sheet ?? 'closed'} visible={!!state.sheet} closing={closing} onClose={close} onDismiss={onDismiss}>{content}</Sheet>;
}

function SentenceEditor({ state, dispatch }: { state: Session; dispatch: Dispatch<Action> }) {
  const [text, setText] = useState(sentenceText(state.sentence));
  return <>
    <Copy role="label" nativeID="sentence-label">Your sentence</Copy>
    <BottomSheetTextInput accessibilityLabel="Your sentence" accessibilityLabelledBy="sentence-label" value={text} onChangeText={setText}
      multiline style={styles.input} textAlignVertical="top" selectionColor={tokens.color.coral} />
    <Copy role="supporting" style={styles.muted}>{text.trim().length}/{MAX_SENTENCE_CHARACTERS} characters · {state.muted ? 'Save the draft, then tap Save sentence to add it to your transcript.' : 'Nothing is spoken until you tap Speak sentence.'}</Copy>
    <Button icon="check" disabled={!text.trim() || text.trim().length > MAX_SENTENCE_CHARACTERS}
      onPress={() => dispatch({ type: 'edit-sentence', draftId: state.sentence.id, revision: state.sentence.revision, text })}>Save draft</Button>
  </>;
}

function Correction({ state, dispatch }: { state: Session; dispatch: Dispatch<Action> }) {
  const [text, setText] = useState(state.phrases.at(-1)?.text ?? '');
  return <>
    <Copy role="label" nativeID="phrase-label">Your phrase</Copy>
    <BottomSheetTextInput accessibilityLabel="Your phrase" accessibilityLabelledBy="phrase-label" value={text} onChangeText={setText} multiline maxLength={500} style={styles.input} textAlignVertical="top" selectionColor={tokens.color.coral} />
    <Copy role="supporting" style={styles.muted}>The original stays in your transcript.</Copy>
    <Button icon={state.muted ? 'check' : 'volume'} disabled={!text.trim()} onPress={() => dispatch({ type: 'correct', text })}>{state.muted ? 'Save correction' : 'Save & speak'}</Button>
    <Button variant="plain" onPress={() => dispatch({ type: 'sign-again' })}>Sign it again instead</Button>
  </>;
}

function MenuRow({ label, icon, onPress, disabled }: { label: string; icon: IconName; onPress: () => void; disabled?: boolean }) {
  return <Touch accessibilityRole="button" accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress} style={({ pressed }) => [styles.menuRow, pressed && { backgroundColor: `${tokens.color.paper}12` }, disabled && { opacity: 0.4 }]}>
    <Icon name={icon} /><Copy style={{ flex: 1 }}>{label}</Copy><Icon name="arrow" size={18} />
  </Touch>;
}
const styles = StyleSheet.create({
  muted: { color: tokens.color.onInkMuted },
  center: { textAlign: 'center' },
  empty: { paddingVertical: 28, alignItems: 'center', gap: 16 },
  phrase: { gap: 12, paddingVertical: 20, borderBottomWidth: 1, borderColor: `${tokens.color.onInkMuted}55` },
  original: { marginTop: 8, paddingTop: 12, borderTopWidth: 1, borderColor: `${tokens.color.onInkMuted}55`, gap: 4 },
  input: { ...textStyles.caption, color: tokens.color.paper, minHeight: 130, maxHeight: 210, borderWidth: 1.5, borderColor: tokens.color.onInkMuted, borderRadius: 18, backgroundColor: tokens.color.inkStrong, padding: 16 },
  menuRow: { flexDirection: 'row', alignItems: 'center', minHeight: 56, gap: 12, borderBottomWidth: 1, borderColor: `${tokens.color.onInkMuted}55`, paddingVertical: 10 },
});
