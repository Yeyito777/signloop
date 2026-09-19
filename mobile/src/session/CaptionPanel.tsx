import { useEffect, useRef, useState, type Dispatch } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import Animated from 'react-native-reanimated';
import type { IntegrationKit } from '../integrations/contracts';
import { Button, Copy, Icon, IconButton } from '../ui/primitives';
import { useMotion } from '../ui/motion';
import { tokens } from '../ui/theme';
import { captionPresentation } from './captionPresentation';
import type { Action, Session } from './model';

export function CaptionPanel({ state, mode, dispatch }: { state: Session; mode: IntegrationKit['mode']; dispatch: Dispatch<Action> }) {
  const { enter, layout } = useMotion();
  const { phrase, text, label, delivery, activity, notice, draft } = captionPresentation(state, mode);
  const lastPhrase = useRef(phrase);
  const scroll = useRef<ScrollView>(null);
  const [corrected, setCorrected] = useState(false);
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
  return <Animated.View layout={layout} style={styles.bubble}>
    <View style={styles.labelRow}>
      <Copy role="label" style={styles.muted}>{label}</Copy>
      {corrected && <Animated.View entering={enter}><Icon name="check" color={tokens.color.successInk} size={18} /></Animated.View>}
    </View>
    <ScrollView ref={scroll} style={styles.textScroll} contentContainerStyle={styles.textContent} showsVerticalScrollIndicator keyboardShouldPersistTaps="handled">
      <Animated.View key={draft ? 'draft' : phrase?.id ?? 'empty'} entering={enter}>
        <Copy role="caption" selectable accessibilityLiveRegion={draft ? 'none' : 'polite'} style={!phrase && !draft ? styles.empty : undefined}>{text}</Copy>
      </Animated.View>
      {!!notice && <Animated.View entering={enter} style={styles.notice}><Icon name="info" size={18} /><Copy role="supporting" style={styles.noticeText}>{notice}</Copy></Animated.View>}
    </ScrollView>
    {!!activity && <Animated.View key={activity} entering={enter} style={styles.activity}><View style={styles.dot} /><Copy role="supporting" accessibilityLiveRegion="polite" style={styles.muted}>{activity}</Copy></Animated.View>}
    {phrase && <View style={styles.tools}>
      <Copy role="supporting" accessibilityLiveRegion="polite" style={styles.status}>{status}</Copy>
      <IconButton icon="edit" label="Correct this phrase" onPress={() => dispatch({ type: 'open-sheet', sheet: 'correction' })} />
      <IconButton icon="repeat" label="Replay this phrase" disabled={state.muted || state.paused} onPress={() => dispatch({ type: 'replay' })} />
    </View>}
    {(state.phase === 'uncertain' || state.phase === 'offline') && <Button variant="plain" icon="repeat" onPress={() => dispatch({ type: 'retry' })}>{state.phase === 'offline' ? 'Try connection again' : 'Try that phrase again'}</Button>}
    {state.phase === 'voice-error' && <Button variant="plain" icon="volume" onPress={() => dispatch({ type: 'replay' })}>Try voice again</Button>}
    {!phrase && !draft && !notice && mode === 'camera' && <Copy role="supporting" style={styles.muted}>Translation and voice are coming next.</Copy>}
  </Animated.View>;
}

const styles = StyleSheet.create({
  bubble: { flexShrink: 1, minHeight: 122, backgroundColor: tokens.color.paper, borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 20, borderTopLeftRadius: 4, paddingHorizontal: 16, paddingTop: 12, paddingBottom: 8, gap: 8, boxShadow: `0px 4px 0px ${tokens.color.captionShadow}` },
  labelRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 20 },
  muted: { color: tokens.color.muted },
  textScroll: { flexShrink: 1 },
  textContent: { paddingBottom: 4, gap: 12 },
  empty: { color: tokens.color.muted },
  activity: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 24 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: tokens.color.ink },
  notice: { flexDirection: 'row', alignItems: 'flex-start', gap: 8, paddingTop: 8 },
  noticeText: { flex: 1 },
  tools: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  status: { color: tokens.color.muted, flex: 1 },
});
