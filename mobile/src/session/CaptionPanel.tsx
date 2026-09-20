import { useEffect, useRef, useState, type Dispatch } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import Animated from 'react-native-reanimated';
import type { IntegrationKit } from '../integrations/contracts';
import { Button, Copy, Icon, IconButton, Touch } from '../ui/primitives';
import { useMotion } from '../ui/motion';
import { tokens } from '../ui/theme';
import { captionPresentation } from './captionPresentation';
import { expressionNotice } from '../integrations/expression';
import type { Action, Session } from './model';
import type { DetectionEvent } from '../../modules/signloop-camera';
import { freshObservation, nameLetters } from '../integrations/localSign';
import { canCapture } from './model';

export function CaptionPanel({ state, mode, dispatch, detection, showScores }: {
  state: Session; mode: IntegrationKit['mode']; dispatch: Dispatch<Action>;
  detection?: DetectionEvent | null; showScores?: boolean;
}) {
  const { enter } = useMotion();
  const { phrase, text, label, delivery, activity, notice, draft } = captionPresentation(state, mode);
  const lastPhrase = useRef(phrase);
  const scroll = useRef<ScrollView>(null);
  const [corrected, setCorrected] = useState(false);
  const [now, setNow] = useState(Date.now());
  const [manual, setManual] = useState(false);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 200); return () => clearInterval(timer); }, []);
  const current = detection?.captureId === state.captureId && detection.mode === state.recognitionMode && canCapture(state) ? detection : null;
  const fresh = current && freshObservation(current.observedAtMS, now);
  const letter = fresh && current.letter && nameLetters.includes(current.letter) ? current.letter : null;
  useEffect(() => {
    if (state.candidate) scroll.current?.scrollTo({ y: 0, animated: false });
  }, [state.candidate?.attemptId]);
  useEffect(() => {
    const previous = lastPhrase.current;
    lastPhrase.current = phrase;
    if (previous?.id !== phrase?.id || previous?.text !== phrase?.text) scroll.current?.scrollTo({ y: 0, animated: false });
    const changed = !!phrase && previous?.id === phrase.id && previous.text !== phrase.text;
    setCorrected(changed);
    if (!changed) return;
    const timer = setTimeout(() => setCorrected(false), 2200);
    return () => clearTimeout(timer);
  }, [phrase?.id, phrase?.text]);
  const status = corrected ? `Correction saved${delivery ? ` · ${delivery}` : ''}` : delivery;
  return <View style={styles.bubble}>
    <View style={styles.labelRow}>
      <View style={styles.labels}>
        <View style={styles.labelText}><Copy role="label" style={styles.muted}>{label}</Copy>
          {corrected && <Animated.View entering={enter}><Icon name="check" color={tokens.color.successInk} size={18} /></Animated.View>}
        </View>
        {!!status && <Copy role="supporting" accessibilityLiveRegion="polite" style={styles.muted}>{status}</Copy>}
      </View>
      {phrase && <View style={styles.tools}>
        <IconButton icon="edit" label="Correct this phrase" onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
        <IconButton icon="repeat" label="Replay this phrase" disabled={state.muted || state.paused} onPress={() => dispatch({ type: 'replay' })} />
      </View>}
    </View>
    <ScrollView ref={scroll} style={styles.textScroll} contentContainerStyle={styles.textContent} showsVerticalScrollIndicator keyboardShouldPersistTaps="handled">
      {mode !== 'demo' && <>
        <View style={{ flexDirection: 'row', gap: 8 }}>
          {(['signs', 'spelling'] as const).map(value => <Button key={value}
            variant={state.recognitionMode === value ? 'secondary' : 'plain'}
            disabled={!canCapture(state)} onPress={() => dispatch({ type: 'recognition-mode', mode: value })}>
            {value === 'signs' ? 'Signs' : 'Spell name'}
          </Button>)}
        </View>
        {!!current && <Copy role="supporting">{current.detail}{current.expression ? ` · ${current.expression}` : ''}</Copy>}
        {state.recognitionMode === 'spelling' && <>
          <Copy role="caption">{state.spellingDraft || 'Spelling…'}</Copy>
          <Copy>Letter guess: {letter ?? 'Watching…'} · verify before Add</Copy>
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            <Button disabled={!letter} onPress={() => {
              if (letter && current && freshObservation(current.observedAtMS)) dispatch({ type: 'add-letter', letter });
            }}>Add letter</Button>
            <Button variant="plain" disabled={!state.spellingDraft} onPress={() => dispatch({ type: 'delete-letter' })}>Delete</Button>
            <Button variant="plain" onPress={() => setManual(!manual)}>Manual letters</Button>
          </View>
          {manual && <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {nameLetters.map(value => <Button key={value} variant="plain" disabled={!canCapture(state)}
              onPress={() => dispatch({ type: 'add-letter', letter: value })}>{value}</Button>)}
            <Button variant="plain" onPress={() => dispatch({ type: 'clear-spelling' })}>Clear</Button>
          </View>}
          <Button disabled={!state.spellingDraft || !canCapture(state)} onPress={() => dispatch({ type: 'confirm-spelling' })}>Confirm spelled name</Button>
          <Copy role="supporting">A U R E L I O only · one hand · nothing is added or spoken automatically.</Copy>
        </>}
        {showScores && state.recognitionMode === 'signs' && <>
          <Copy role="supporting">Geometric distance · lower is closer · not probability</Copy>
          {current?.scores.slice().sort((a,b) => (a.distance ?? Infinity)-(b.distance ?? Infinity)).map(row =>
            <Copy role="supporting" key={row.label}>{row.label}: {fresh && row.distance !== null ? row.distance.toFixed(3) : '—'}</Copy>)}
          <Copy role="supporting">{current?.fps ?? 0} FPS · tracking {current?.trackingMS ?? 0} ms · matching {current?.matchMS ?? 0} ms</Copy>
        </>}
      </>}
      {!!expressionNotice(state.expression) && !state.paused && <Copy role="supporting" style={styles.muted}>{expressionNotice(state.expression)}</Copy>}
      {state.candidate && !state.paused && <View style={styles.notice}>
        <View style={{ flex: 1, gap: 8 }}>
          <Copy role="supporting">{state.candidate.selected
            ? 'Choice held for you. Confirm it or choose another.'
            : 'Uncertain matches update as you sign. Tap one to hold it, then confirm.'}</Copy>
          <View style={styles.choices}>
            {state.candidate.options.map(option => <Touch key={option.label} accessibilityRole="radio"
              accessibilityLabel={option.text} accessibilityState={{ selected: state.candidate!.selected && option.label === state.candidate!.label }}
              onPress={() => dispatch({ type: 'select-candidate', attemptId: state.candidate!.attemptId, label: option.label })}
              style={[styles.choice, state.candidate!.selected && option.label === state.candidate!.label && styles.selectedChoice]}>
              <Copy role="label" style={{ flexShrink: 1 }}>{option.text}</Copy>
              {state.candidate!.selected && option.label === state.candidate!.label && <Icon name="check" size={18} />}
            </Touch>)}
          </View>
          <Button icon="check" disabled={!state.candidate.selected} onPress={() => dispatch({ type: 'confirm-candidate', attemptId: state.candidate!.attemptId })}>Confirm selected sign</Button>
          <Button variant="plain" onPress={() => dispatch({ type: 'reject-candidate', attemptId: state.candidate!.attemptId })}>None of these</Button>
        </View>
      </View>}
      {!state.candidate && state.signPreview && !state.paused && <View style={styles.preview}>
        <Copy role="supporting" style={styles.muted}>Live guess · not ready to confirm</Copy>
        <Copy role="label">{state.signPreview}</Copy>
        <Copy role="supporting" style={styles.muted}>Keep signing with your hands and shoulders in view.</Copy>
      </View>}
      {(!state.candidate || phrase || draft) && <Animated.View key={draft ? 'draft' : phrase?.id ?? 'empty'} entering={enter}>
        <Copy role={phrase || draft ? 'featuredCaption' : 'captionLarge'} selectable accessibilityLiveRegion={draft ? 'none' : 'polite'} style={!phrase && !draft ? styles.empty : undefined}>{text}</Copy>
      </Animated.View>}
      {!!notice && <Animated.View entering={enter} style={styles.notice}><Icon name="info" size={18} /><Copy role="supporting" style={styles.noticeText}>{notice}</Copy></Animated.View>}
      {!!activity && <Animated.View key={activity} entering={enter} style={styles.activity}><View style={styles.dot} /><Copy role="supporting" accessibilityLiveRegion="polite" style={styles.muted}>{activity}</Copy></Animated.View>}
      {(state.phase === 'uncertain' || state.phase === 'offline') && <Button variant="plain" icon="repeat" onPress={() => dispatch({ type: 'retry' })}>{state.phase === 'offline' ? 'Try connection again' : 'Try that phrase again'}</Button>}
      {state.phase === 'voice-error' && <Button variant="plain" icon="volume" onPress={() => dispatch({ type: 'replay' })}>Try voice again</Button>}
      {!state.candidate && state.reviewedAttempt !== null && !state.paused && <Button variant="plain" icon="repeat" onPress={() => dispatch({ type: 'sign-again' })}>Review another sign</Button>}
      {!phrase && !draft && !notice && !state.candidate && !state.signPreview && mode !== 'demo' && state.recognitionMode === 'signs' && <Copy role="supporting" style={styles.muted}>11-sign preview. Sign with your hands and shoulders in view. Tap the intended choice to hold it, then confirm. Voice is optional in Settings.</Copy>}
    </ScrollView>
  </View>;
}

const styles = StyleSheet.create({
  bubble: { flex: 1, paddingHorizontal: 8, paddingBottom: 4, gap: 4 },
  labelRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  labels: { flex: 1 },
  labelText: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  muted: { color: tokens.color.muted },
  textScroll: { flex: 1 },
  textContent: { paddingBottom: 4, gap: 12 },
  empty: { color: tokens.color.muted },
  activity: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 24 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: tokens.color.ink },
  notice: { flexDirection: 'row', alignItems: 'flex-start', gap: 8, paddingTop: 8 },
  noticeText: { flex: 1 },
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  choice: { minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12, paddingVertical: 10,
    borderRadius: 14, borderWidth: 1.5, borderColor: tokens.color.line, backgroundColor: tokens.color.paper },
  selectedChoice: { borderColor: tokens.color.ink, backgroundColor: tokens.color.butter },
  preview: { gap: 4, paddingTop: 8 },
  tools: { flexDirection: 'row', alignItems: 'center', gap: 2 },
});
