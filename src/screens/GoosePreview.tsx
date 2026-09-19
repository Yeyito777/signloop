import { useState } from 'react';
import { KeyboardAvoidingView, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { MrGoose } from '../components/MrGoose';
import { colors } from '../components/goose/settings';
import { useGooseVoice } from '../hooks/useGooseVoice';
import { useMotionPreferences } from '../hooks/useMotionPreferences';

export function GoosePreview() {
  const [animationEnabled, setAnimationEnabled] = useState(true);
  const [asrText, setAsrText] = useState('');
  const { reducedMotion } = useMotionPreferences();
  const voice = useGooseVoice();
  const trimmed = asrText.trim();
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
        <MrGoose animationEnabled={animationEnabled} style={styles.goose} />
        {voice.lastSpoken ? <Text style={styles.spoken} accessibilityLiveRegion="polite">{voice.lastSpoken}</Text> : null}
        <View style={styles.controls}>
          <Text style={styles.caption}>Your sign language companion.</Text>
          <TextInput
            accessibilityLabel="English from ASR"
            placeholder="Type what ASR would output…"
            placeholderTextColor="#A39E93"
            value={asrText}
            onChangeText={setAsrText}
            multiline
            style={styles.input}
          />
          <View style={styles.row}>
            <Pressable accessibilityRole="button" accessibilityLabel="Speak" disabled={speakDisabled}
              accessibilityHint="Sends the English text to Mr. Goose’s ElevenLabs voice."
              onPress={() => { void voice.speak(asrText); }}
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
          <Pressable accessibilityRole="button"
            accessibilityLabel={animationEnabled ? 'Pause animation' : 'Resume animation'}
            accessibilityHint={reducedMotion ? 'Reduce Motion is on. Mr. Goose will remain still.' : 'Changes Mr. Goose’s gentle idle motion.'}
            onPress={() => setAnimationEnabled(value => !value)}
            style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}>
            <Text style={styles.buttonIcon} accessible={false}>{animationEnabled ? 'Ⅱ' : '▷'}</Text>
            <Text style={styles.buttonText}>{animationEnabled ? 'Pause animation' : 'Resume animation'}</Text>
          </Pressable>
          <Text style={styles.note} accessibilityLiveRegion="polite">{voiceNote}</Text>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  avoid: { flex: 1 },
  heading: { alignItems: 'center', paddingTop: 26, paddingHorizontal: 24 },
  eyebrow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 14 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#788775' },
  eyebrowText: { color: '#6D7668', fontSize: 10, fontWeight: '700', letterSpacing: 2.2 },
  title: { fontSize: 43, fontWeight: '700', letterSpacing: -1.8, color: '#30372F' },
  goose: { flex: 1, minHeight: 120 },
  spoken: { color: '#5C6558', fontSize: 14, textAlign: 'center', paddingHorizontal: 28, paddingBottom: 8 },
  controls: { alignItems: 'center', paddingHorizontal: 24, paddingBottom: 20 },
  caption: { color: '#817D72', fontSize: 13, marginBottom: 14 },
  input: {
    width: '100%', maxWidth: 310, minHeight: 72, maxHeight: 110, borderRadius: 18, paddingHorizontal: 16, paddingVertical: 12,
    backgroundColor: '#FFFDF8', borderWidth: 1, borderColor: '#D8D2C4', color: '#30372F', fontSize: 15, marginBottom: 12, textAlignVertical: 'top',
  },
  row: { width: '100%', maxWidth: 310, flexDirection: 'row', gap: 10, marginBottom: 10 },
  half: { flex: 1, maxWidth: undefined },
  button: { minHeight: 56, width: '100%', maxWidth: 310, borderRadius: 28, backgroundColor: '#394738', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 11, padding: 16 },
  buttonPressed: { backgroundColor: '#53634D' },
  buttonDisabled: { opacity: 0.4 },
  buttonIcon: { color: '#FFFDF5', fontSize: 19, fontWeight: '600' },
  buttonText: { color: '#FFFDF5', fontSize: 15, fontWeight: '600' },
  secondary: { minHeight: 56, borderRadius: 28, borderWidth: 1.5, borderColor: '#394738', alignItems: 'center', justifyContent: 'center', padding: 16 },
  secondaryPressed: { backgroundColor: '#E7E2D4' },
  secondaryText: { color: '#394738', fontSize: 15, fontWeight: '600' },
  note: { color: '#8C887D', fontSize: 11, marginTop: 14, textAlign: 'center' },
});
