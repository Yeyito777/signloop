import { useEffect, useRef, useState, type Dispatch } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import type { Framing, TranslationEvent } from '../integrations/contracts';
import { Button, Copy, Icon, Touch, type IconName } from '../ui/primitives';
import { Sheet } from '../ui/Sheet';
import { textStyles, tokens } from '../ui/theme';
import type { Action, Session } from './model';

export function ConversationSheets({ state, dispatch, onEnd, demo }: { state: Session; dispatch: Dispatch<Action>; onEnd: () => void; demo: boolean }) {
  // Retain the modal through its native dismissal animation instead of unmounting it mid-slide.
  const [presented, setPresented] = useState(state.sheet);
  const afterDismiss = useRef<(() => void) | null>(null);
  useEffect(() => { if (state.sheet) setPresented(state.sheet); }, [state.sheet]);
  const close = () => dispatch({ type: 'close-sheet' });
  const presentation = { visible: !!state.sheet, onDismiss: () => {
    if (!state.sheet) setPresented(null);
    const action = afterDismiss.current;
    afterDismiss.current = null;
    action?.();
  } };
  const end = () => { afterDismiss.current = onEnd; dispatch({ type: 'pause' }); close(); };
  switch (state.sheet ?? presented) {
    case 'transcript': return <Sheet {...presentation} title="This conversation" onClose={close}>
      <Copy role="supporting" style={styles.muted}>Your phrases stay here until you end this conversation.</Copy>
      {state.phrases.length === 0 ? <View style={styles.empty}><Icon name="transcript" size={32} /><Copy role="sectionTitle">No phrases yet.</Copy><Copy style={styles.center}>Your translated words will appear here.</Copy></View> : state.phrases.map((phrase, i) => <View key={phrase.id} style={styles.phrase}>
        <Copy role="label" style={styles.muted}>{String(i + 1).padStart(2, '0')} · {phrase.original ? 'Corrected' : demo ? 'Sample caption' : phrase.status === 'played' ? 'Spoken' : 'Caption'}</Copy>
        <Copy role="caption" selectable>{phrase.text}</Copy>
        {phrase.original && <View style={styles.original}><Copy role="supporting" style={styles.muted}>Original caption</Copy><Copy>{phrase.original}</Copy></View>}
      </View>)}
      <Button variant="secondary" onPress={close}>Back to conversation</Button>
    </Sheet>;
    case 'correction': return <Sheet {...presentation} title="Make a correction" onClose={close}><Correction key={state.phrases.at(-1)?.id} state={state} dispatch={dispatch} /></Sheet>;
    case 'menu': return <Sheet {...presentation} title="Conversation" onClose={close}>
      <MenuRow icon="transcript" label="View transcript" onPress={() => dispatch({ type: 'open-sheet', sheet: 'transcript' })} />
      <MenuRow icon="edit" label="Correct last phrase" disabled={!state.phrases.length} onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
      <MenuRow icon={state.muted ? 'muted' : 'volume'} label={state.muted ? 'Turn voice on' : 'Turn voice off'} onPress={() => dispatch({ type: 'mute' })} />
      <MenuRow icon="exit" label="End conversation" onPress={() => dispatch({ type: 'open-sheet', sheet: 'end' })} />
    </Sheet>;
    case 'end': return <Sheet {...presentation} title="All done for now?" onClose={close}>
      <Copy>End this conversation? Its transcript will be cleared.</Copy>
      <Button icon="exit" onPress={end}>End conversation</Button>
      <Button variant="plain" onPress={close}>Keep going</Button>
    </Sheet>;
    case 'demo': return <Sheet {...presentation} title="Preview states" onClose={close}>
      <Copy role="supporting" style={styles.muted}>Sample camera, captions, and silent voice. These controls are only for reviewing the UI.</Copy>
      <MenuRow icon="play" label="Run sample conversation" onPress={() => dispatch({ type: 'retry' })} />
      {([
        ['hands-missing', 'hand', 'Hands out of view'], ['too-close', 'frame', 'Too close'], ['too-far', 'frame', 'Too far'],
        ['low-light', 'sun', 'Low light'], ['away', 'frame', 'No one in frame'],
      ] as [Framing, IconName, string][]).map(([framing, icon, label]) => <MenuRow key={framing} icon={icon} label={label} onPress={() => dispatch({ type: 'demo-framing', framing })} />)}
      {([
        ['Uncertain translation', 'info', { type: 'uncertain' }],
        ['Connection lost', 'offline', { type: 'offline' }],
        ['Long caption', 'transcript', { type: 'accepted', id: `long-${state.captureId}`, text: 'Could we find somewhere a little quieter? I would love to hear more about your project, and it would be easier to have a conversation by the window.', emotion: 'neutral' }],
      ] as [string, IconName, TranslationEvent][]).map(([label, icon, event]) => <MenuRow key={label} icon={icon} label={label} onPress={() => dispatch({ type: 'demo-event', event })} />)}
    </Sheet>;
    default: return null;
  }
}

function Correction({ state, dispatch }: { state: Session; dispatch: Dispatch<Action> }) {
  const [text, setText] = useState(state.phrases.at(-1)?.text ?? '');
  return <>
    <Copy role="label" nativeID="phrase-label">Your phrase</Copy>
    <TextInput accessibilityLabel="Your phrase" accessibilityLabelledBy="phrase-label" value={text} onChangeText={setText} multiline maxLength={500} style={styles.input} textAlignVertical="top" selectionColor={tokens.color.coral} />
    <Copy role="supporting" style={styles.muted}>The original stays in your transcript.</Copy>
    <Button icon={state.muted ? 'check' : 'volume'} disabled={!text.trim()} onPress={() => dispatch({ type: 'correct', text })}>{state.muted ? 'Save correction' : 'Save & speak'}</Button>
    <Button variant="plain" onPress={() => dispatch({ type: 'sign-again' })}>Sign it again instead</Button>
  </>;
}

function MenuRow({ label, icon, onPress, disabled }: { label: string; icon: IconName; onPress: () => void; disabled?: boolean }) {
  return <Touch accessibilityRole="button" accessibilityState={{ disabled: !!disabled }} disabled={disabled} onPress={onPress} style={({ pressed }) => [styles.menuRow, pressed && { backgroundColor: tokens.color.butter }, disabled && { opacity: 0.4 }]}>
    <Icon name={icon} /><Copy style={{ flex: 1 }}>{label}</Copy><Icon name="arrow" size={18} />
  </Touch>;
}
const styles = StyleSheet.create({
  muted: { color: tokens.color.muted },
  center: { textAlign: 'center' },
  empty: { paddingVertical: 28, alignItems: 'center', gap: 16 },
  phrase: { gap: 8, borderWidth: 1.5, borderColor: tokens.color.ink, padding: 16, borderRadius: 20, borderBottomLeftRadius: 4 },
  original: { marginTop: 8, paddingTop: 12, borderTopWidth: 1, borderColor: tokens.color.line, gap: 4 },
  input: { ...textStyles.caption, color: tokens.color.ink, minHeight: 130, maxHeight: 210, borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 16, backgroundColor: tokens.color.butter, padding: 16 },
  menuRow: { flexDirection: 'row', alignItems: 'center', minHeight: 52, gap: 12, borderBottomWidth: 1, borderColor: tokens.color.line, paddingVertical: 8 },
});
