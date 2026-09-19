import { useState } from 'react';
import { KeyboardAvoidingView, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { MrGoose } from '../components/MrGoose';
import { gooseEmotions, type GooseActivity, type GooseEmotion } from '../components/goose/motion';
import { colors } from '../components/goose/settings';
import { useGooseVoice } from '../hooks/useGooseVoice';
import { useMotionPreferences } from '../hooks/useMotionPreferences';

const emotionLabel: Record<GooseEmotion, string> = {
  joy: 'Joy',
  sadness: 'Sadness',
  anger: 'Anger',
  fear: 'Fear',
};

function activityFromVoice(status: string, textFocused: boolean): GooseActivity {
  if (status === 'speaking') return 'speaking';
  if (status === 'loading') return 'thinking';
  if (textFocused) return 'watching';
  return 'idle';
}

function EmotionDropdown({ value, onChange }: { value: GooseEmotion; onChange: (emotion: GooseEmotion) => void }) {
  const [open, setOpen] = useState(false);
  return (
    <View style={styles.dropdown}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Emotion, ${emotionLabel[value]}`}
        accessibilityHint="Opens a list of emotions"
        accessibilityState={{ expanded: open }}
        onPress={() => setOpen(current => !current)}
        style={({ pressed }) => [styles.dropdownButton, pressed && styles.dropdownPressed]}>
        <Text style={styles.dropdownLabel}>{emotionLabel[value]}</Text>
        <Text style={styles.dropdownCaret} accessible={false}>{open ? '▴' : '▾'}</Text>
      </Pressable>
      {open ? (
        <View style={styles.dropdownMenu} accessibilityRole="menu">
          {gooseEmotions.map(name => {
            const selected = value === name;
            return (
              <Pressable key={name} accessibilityRole="menuitem" accessibilityState={{ selected }}
                accessibilityLabel={emotionLabel[name]}
                onPress={() => { onChange(name); setOpen(false); }}
                style={({ pressed }) => [styles.dropdownItem, selected && styles.dropdownItemSelected, pressed && styles.dropdownItemPressed]}>
                <Text style={[styles.dropdownItemText, selected && styles.dropdownItemTextSelected]}>{emotionLabel[name]}</Text>
              </Pressable>
            );
          })}
        </View>
      ) : null}
    </View>
  );
}

export function GoosePreview() {
  const [animationEnabled, setAnimationEnabled] = useState(true);
  const [asrText, setAsrText] = useState('');
  const [textFocused, setTextFocused] = useState(false);
  const [emotion, setEmotion] = useState<GooseEmotion>('joy');
  const { reducedMotion } = useMotionPreferences();
  const voice = useGooseVoice();
  const trimmed = asrText.trim();
  const activity = activityFromVoice(voice.status, textFocused);
  const speakDisabled = !voice.configured || !trimmed || voice.status === 'loading';
  const stopDisabled = voice.status !== 'loading' && voice.status !== 'speaking';
  const voiceNote = !voice.configured ? voice.setupMessage
    : voice.status === 'loading' ? 'Getting the goose ready…'
    : voice.status === 'speaking' ? 'Speaking.'
    : voice.status === 'error' && voice.error ? voice.error
    : reducedMotion ? 'Keeping still · Reduce Motion is on'
    : animationEnabled ? 'Just taking it slow.'
    : 'Taking a little breather.';

  return (
    <SafeAreaView style={styles.screen}>
      <KeyboardAvoidingView style={styles.avoid} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <View style={styles.heading}>
          <View style={styles.eyebrow}><View style={styles.dot} /><Text style={styles.eyebrowText}>SIGNLOOP</Text></View>
          <Text accessibilityRole="header" style={styles.title}>Mr. Goose</Text>
        </View>
        <MrGoose animationEnabled={animationEnabled} activity={activity} emotion={emotion} style={styles.goose} />
        {voice.lastSpoken ? <Text style={styles.spoken} accessibilityLiveRegion="polite">{voice.lastSpoken}</Text> : null}
        <View style={styles.controls}>
          <TextInput
            accessibilityLabel="Text for Mr. Goose to say"
            placeholder="Type anything for Mr. Goose to say…"
            placeholderTextColor="#A39E93"
            value={asrText}
            onChangeText={setAsrText}
            onFocus={() => setTextFocused(true)}
            onBlur={() => setTextFocused(false)}
            multiline
            style={styles.input}
          />
          <View style={styles.row}>
            <Pressable accessibilityRole="button" accessibilityLabel="Speak" disabled={speakDisabled}
              accessibilityHint="Speaks whatever you typed in Mr. Goose’s ElevenLabs voice."
              onPress={() => { void voice.speak(asrText, emotion); }}
              style={({ pressed }) => [styles.button, styles.half, speakDisabled && styles.buttonDisabled, pressed && !speakDisabled && styles.buttonPressed]}>
              <Text style={styles.buttonText}>Speak</Text>
            </Pressable>
            <Pressable accessibilityRole="button" accessibilityLabel="Stop" disabled={stopDisabled}
              accessibilityHint="Stops Mr. Goose from speaking."
              onPress={voice.stop}
              style={({ pressed }) => [styles.secondary, styles.half, stopDisabled && styles.buttonDisabled, pressed && !stopDisabled && styles.secondaryPressed]}>
              <Text style={styles.secondaryText}>Stop</Text>
            </Pressable>
          </View>
          <View style={styles.row}>
            <EmotionDropdown value={emotion} onChange={setEmotion} />
            <Pressable accessibilityRole="button"
              accessibilityLabel={animationEnabled ? 'Pause animation' : 'Resume animation'}
              accessibilityHint={reducedMotion ? 'Reduce Motion is on. Mr. Goose will remain still.' : 'Changes Mr. Goose’s gentle idle motion.'}
              onPress={() => setAnimationEnabled(value => !value)}
              style={({ pressed }) => [styles.button, styles.half, pressed && styles.buttonPressed]}>
              <Text style={styles.buttonIcon} accessible={false}>{animationEnabled ? 'Ⅱ' : '▷'}</Text>
              <Text style={styles.buttonText}>{animationEnabled ? 'Pause' : 'Resume'}</Text>
            </Pressable>
          </View>
          <Text style={styles.note} accessibilityLiveRegion="polite">{voiceNote}</Text>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  avoid: { flex: 1 },
  heading: { alignItems: 'center', paddingTop: 12, paddingHorizontal: 24 },
  eyebrow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 6 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#788775' },
  eyebrowText: { color: '#6D7668', fontSize: 10, fontWeight: '700', letterSpacing: 2.2 },
  title: { fontSize: 32, fontWeight: '700', letterSpacing: -1.4, color: '#30372F' },
  goose: { flex: 1, minHeight: 280 },
  spoken: { color: '#5C6558', fontSize: 14, textAlign: 'center', paddingHorizontal: 28, paddingBottom: 6 },
  controls: { alignItems: 'center', paddingHorizontal: 24, paddingTop: 4, paddingBottom: 14, overflow: 'visible', zIndex: 2 },
  input: {
    width: '100%', maxWidth: 310, minHeight: 48, maxHeight: 88, borderRadius: 16, paddingHorizontal: 16, paddingVertical: 10,
    backgroundColor: '#FFFDF8', borderWidth: 1, borderColor: '#D8D2C4', color: '#30372F', fontSize: 15, marginBottom: 10, textAlignVertical: 'top',
  },
  row: { width: '100%', maxWidth: 310, flexDirection: 'row', gap: 10, marginBottom: 10, overflow: 'visible', zIndex: 2 },
  dropdown: { flex: 1, position: 'relative', zIndex: 3 },
  dropdownButton: {
    minHeight: 48, borderRadius: 24, borderWidth: 1.5, borderColor: '#394738', backgroundColor: '#FFFDF8',
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8, paddingHorizontal: 14,
  },
  dropdownPressed: { backgroundColor: '#E7E2D4' },
  dropdownLabel: { color: '#394738', fontSize: 15, fontWeight: '600' },
  dropdownCaret: { color: '#394738', fontSize: 12 },
  dropdownMenu: {
    position: 'absolute', left: 0, right: 0, bottom: 54, backgroundColor: '#FFFDF8',
    borderRadius: 16, borderWidth: 1, borderColor: '#D8D2C4', overflow: 'hidden',
  },
  dropdownItem: { paddingHorizontal: 14, paddingVertical: 11 },
  dropdownItemSelected: { backgroundColor: '#394738' },
  dropdownItemPressed: { opacity: 0.75 },
  dropdownItemText: { color: '#394738', fontSize: 15, fontWeight: '600' },
  dropdownItemTextSelected: { color: '#FFFDF5' },
  half: { flex: 1, maxWidth: undefined },
  button: { minHeight: 48, width: '100%', maxWidth: 310, borderRadius: 24, backgroundColor: '#394738', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8, paddingHorizontal: 14, paddingVertical: 12 },
  buttonPressed: { backgroundColor: '#53634D' },
  buttonDisabled: { opacity: 0.4 },
  buttonIcon: { color: '#FFFDF5', fontSize: 16, fontWeight: '600' },
  buttonText: { color: '#FFFDF5', fontSize: 15, fontWeight: '600' },
  secondary: { minHeight: 48, borderRadius: 24, borderWidth: 1.5, borderColor: '#394738', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 14, paddingVertical: 12 },
  secondaryPressed: { backgroundColor: '#E7E2D4' },
  secondaryText: { color: '#394738', fontSize: 15, fontWeight: '600' },
  note: { color: '#8C887D', fontSize: 11, marginTop: 2, textAlign: 'center' },
});
