import { useEffect, useRef, type Dispatch } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { Button, Copy, Icon, IconButton, Touch, type IconName } from '../ui/primitives';
import { tokens } from '../ui/theme';
import { captionPresentation } from './captionPresentation';
import type { Action, Session } from './model';
import { MAX_SENTENCE_CHARACTERS, sentenceText } from './sentence';
import { expressionNotice } from '../integrations/expression';

export function SentencePanel({ state, dispatch }: {
  state: Session; dispatch: Dispatch<Action>;
}) {
  const scroll = useRef<ScrollView>(null);
  const text = sentenceText(state.sentence);
  const { phrase, delivery, notice } = captionPresentation(state, 'live');
  const target = { draftId: state.sentence.id, revision: state.sentence.revision };
  const tooLong = text.length > MAX_SENTENCE_CHARACTERS;
  const edited = state.sentence.editedText !== null;
  useEffect(() => { scroll.current?.scrollTo({ y: 0, animated: false }); }, [state.sentence.revision, state.sentence.id]);

  return <View style={styles.panel}>
    <View style={styles.heading}>
      <Copy role="label" style={styles.muted}>{text ? 'Draft · not spoken' : 'Your sentence'}</Copy>
      {!!text && <Copy role="supporting" style={styles.muted}>{text.length}/{MAX_SENTENCE_CHARACTERS}</Copy>}
    </View>
    <ScrollView ref={scroll} style={styles.scroll} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      {!!text && <Copy role="captionLarge" selectable>{text}</Copy>}
      {tooLong && <Copy role="supporting" accessibilityLiveRegion="polite">Your sentence is too long. Edit it or undo a sign to keep it within 500 characters.</Copy>}
      {edited && <Copy role="supporting" style={styles.muted}>Your edit is ready. {state.muted ? 'Save' : 'Speak'} this sentence, or clear it to start signing again.</Copy>}
      {!edited && state.sentence.needsContinuation && <>
        <Copy role="supporting" style={styles.muted}>Your draft is saved. Continue signing or send it as it is.</Copy>
        <Button variant="plain" disabled={state.paused} onPress={() => dispatch({ type: 'continue-sentence', ...target })}>Continue this sentence</Button>
      </>}
      {state.signPreview && !state.paused && <View style={styles.preview}>
        <Copy role="supporting" style={styles.muted}>Reading your next sign…</Copy>
        <Copy role="label">{state.signPreview.text}</Copy>
        <Copy role="supporting" style={styles.muted}>Pause briefly to add it to your sentence.</Copy>
      </View>}
      {!text && !state.signPreview && <Copy role="supporting" style={styles.muted}>
        Sign one word at a time, pausing briefly between signs. Then tap {state.muted ? 'Save sentence' : 'Speak sentence'}.
      </Copy>}
      {!state.paused && !!expressionNotice(state.expression) && <Copy role="supporting" style={styles.muted}>{expressionNotice(state.expression)}</Copy>}
      {phrase && <View style={styles.previous}>
        <View style={styles.heading}>
          <View style={styles.previousLabel}><Copy role="label" style={styles.muted}>Last sentence</Copy>
            <Copy role="supporting" accessibilityLiveRegion="polite" style={styles.muted}>{delivery}</Copy></View>
          <IconButton icon="edit" label="Correct last sentence" onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
          <IconButton icon="repeat" label="Replay last sentence" disabled={state.muted || state.paused} onPress={() => dispatch({ type: 'replay' })} />
        </View>
        <Copy role={text ? 'body' : 'captionLarge'} selectable accessibilityLiveRegion="polite">{phrase.text}</Copy>
      </View>}
      {!!notice && <Copy role="supporting" accessibilityLiveRegion="polite">{notice}</Copy>}
      {state.phase === 'offline' && <Button variant="plain" onPress={() => dispatch({ type: 'retry' })}>Try connection again</Button>}
      {state.phase === 'voice-error' && <Button variant="plain" disabled={state.muted || state.paused} onPress={() => dispatch({ type: 'replay' })}>Try voice again</Button>}
    </ScrollView>
    <View style={styles.actions}>
      <DraftAction label="Edit" icon="edit" disabled={state.paused} onPress={() => dispatch({ type: 'open-sheet', sheet: 'sentence-editor' })} />
      <DraftAction label="Undo" icon="back" disabled={state.paused || edited || !state.sentence.tokens.length} onPress={() => dispatch({ type: 'undo-sign', ...target })} />
      <DraftAction label="Clear" icon="close" disabled={!text} onPress={() => dispatch({ type: 'clear-sentence', ...target })} />
    </View>
    <Button icon={state.muted ? 'check' : 'volume'} disabled={!text || tooLong || state.paused}
      onPress={() => dispatch({ type: 'commit-sentence', ...target })}>{state.muted ? 'Save sentence' : 'Speak sentence'}</Button>
  </View>;
}

function DraftAction({ label, icon, disabled, onPress }: { label: string; icon: IconName; disabled?: boolean; onPress: () => void }) {
  return <Touch accessibilityRole="button" accessibilityLabel={`${label} sentence draft`} accessibilityState={{ disabled: !!disabled }}
    disabled={disabled} onPress={onPress} style={[styles.action, disabled && styles.disabled]}>
    <Icon name={icon} size={18} /><Copy role="label">{label}</Copy>
  </Touch>;
}

const styles = StyleSheet.create({
  panel: { flex: 1, gap: 4, paddingHorizontal: 8, paddingBottom: 4 },
  heading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  muted: { color: tokens.color.muted },
  scroll: { flex: 1 },
  content: { gap: 10, paddingBottom: 8 },
  preview: { gap: 3 },
  previous: { gap: 4, borderTopWidth: 1, borderColor: tokens.color.line, paddingTop: 8 },
  previousLabel: { flex: 1 },
  actions: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', gap: 4 },
  action: { minHeight: 44, flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 8 },
  disabled: { opacity: 0.4 },
});
