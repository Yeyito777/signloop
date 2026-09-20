import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { router } from 'expo-router';
import { ScrollView, StyleSheet, Switch, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { backendOrigin, getVoiceSettings, setVoiceSettings, subscribeVoiceSettings } from '../integrations/voiceSettings';
import { gooseVoice } from '../integrations/voice';
import { Button, Copy, IconButton } from '../ui/primitives';
import { tokens } from '../ui/theme';

export default function Settings() {
  const saved = useSyncExternalStore(subscribeVoiceSettings, getVoiceSettings, getVoiceSettings);
  const [url, setUrl] = useState(saved.url);
  const [token, setToken] = useState(saved.token);
  const [consent, setConsent] = useState(saved.enabled);
  const [message, setMessage] = useState('');
  const [testing, setTesting] = useState(false);
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  useEffect(() => { if (!saved.enabled) setConsent(false); }, [saved.enabled]);
  const save = () => {
    try {
      const origin = url.trim() ? backendOrigin(url) : '';
      if (consent && (!origin || token.trim().length < 24)) throw new Error('Enter the backend URL and access token first.');
      setVoiceSettings({ url: origin, token: token.trim(), enabled: consent });
      setMessage(consent ? 'Voice enabled for this foreground session.' : 'Voice off. Captions stay on-device.');
    } catch (error) { setMessage(error instanceof Error ? error.message : 'Check the settings.'); }
  };
  const testVoice = async () => {
    controller.current?.abort();
    const abort = new AbortController();
    controller.current = abort;
    setTesting(true);
    setMessage('Requesting a short voice sample…');
    try {
      await gooseVoice.speak('Hello from Honk & Tell.', abort.signal, () => setMessage('Playing the voice sample…'));
      if (!abort.signal.aborted) setMessage('Voice playback completed.');
    } catch {
      if (!abort.signal.aborted) setMessage('Voice failed. Check the backend, access token, and ElevenLabs configuration.');
    } finally { if (controller.current === abort) setTesting(false); }
  };
  return <SafeAreaView style={styles.screen}>
    <View style={styles.header}><IconButton icon="back" label="Back" onPress={() => router.back()} /><Copy role="sectionTitle">Voice settings</Copy></View>
    <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <Copy>Recognition runs on your iPhone. Optional voice sends only confirmed or edited English text to your backend and ElevenLabs—not camera images or landmarks.</Copy>
      <Copy role="label">Backend URL</Copy>
      <TextInput accessibilityLabel="Backend URL" value={url} onChangeText={setUrl} autoCapitalize="none" autoCorrect={false} placeholder="http://your-mac.local:8787" keyboardType="url" style={styles.input} />
      <Copy role="label">Backend access token</Copy>
      <TextInput accessibilityLabel="Backend access token" value={token} onChangeText={setToken} autoCapitalize="none" autoCorrect={false} secureTextEntry placeholder="Your backend access token" style={styles.input} />
      <Copy role="supporting">Settings remain in memory only. Use HTTPS outside a trusted development LAN. Configure ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID on the backend, never here.</Copy>
      <View style={styles.row}>
        <Copy style={{ flex: 1 }}>Allow confirmed text uploads for voice this session</Copy>
        <Switch accessibilityLabel="Allow text uploads for voice" value={consent} onValueChange={value => {
          setConsent(value);
          if (!value) setVoiceSettings({ ...getVoiceSettings(), enabled: false });
        }} />
      </View>
      <Copy role="supporting">Consent turns off when the app backgrounds. Turning it off stops future uploads and playback; it cannot retract text already sent or cancel an already-started provider charge. Provider retention policies apply. The goose animation is expressive, not an ASL signing avatar.</Copy>
      <Button icon="check" onPress={save}>Save settings</Button>
      <Button variant="secondary" icon="volume" disabled={!saved.enabled || testing} onPress={() => { void testVoice(); }}>Test voice (sends a short sample)</Button>
      {testing && <Button variant="plain" onPress={() => { controller.current?.abort(); setTesting(false); setMessage('Voice stopped.'); }}>Stop voice</Button>}
      {!!message && <Copy accessibilityLiveRegion="polite">{message}</Copy>}
    </ScrollView>
  </SafeAreaView>;
}
const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { flexDirection: 'row', alignItems: 'center', gap: 10, padding: 12 },
  content: { padding: 24, gap: 16 },
  row: { flexDirection: 'row', gap: 12, alignItems: 'center' },
  input: { borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 12, padding: 14, backgroundColor: tokens.color.paper, color: tokens.color.ink },
});
