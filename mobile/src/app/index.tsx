import { router } from 'expo-router';
import { ScrollView, StyleSheet, View, useWindowDimensions } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { demoKit } from '../integrations/demo';
import { Button, Copy, Wordmark, useReducedMotion } from '../ui/primitives';
import { tokens } from '../ui/theme';

export default function Home() {
  const reducedMotion = useReducedMotion();
  const { height } = useWindowDimensions();
  const Avatar = demoKit.Avatar;
  return <SafeAreaView style={styles.screen}>
    <View style={styles.header}><Wordmark /><Copy role="label" style={styles.demo}>Camera preview</Copy></View>
    <ScrollView contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <Copy role="hero" accessibilityRole="header" style={styles.title}>Ready when{ '\n' }you are.</Copy>
      <View style={[styles.stage, { minHeight: height < 750 ? 200 : 270 }]}>
        <View style={styles.oval} />
        <Avatar mode="idle" emotion="neutral" reducedMotion={reducedMotion} style={styles.goose} />
        <View style={styles.hello}><Copy role="sectionTitle">Hello!</Copy></View>
      </View>
      <Copy role="sectionTitle" style={styles.description}>Sign in ASL.{ '\n' }Your goose says it in English.</Copy>
    </ScrollView>
    <View style={styles.actions}>
      <Button icon="arrow" onPress={() => router.push('/conversation')}>Start conversation</Button>
      <Copy role="supporting" style={styles.note}>Try live hand tracking. Translation and voice are coming next.</Copy>
      <Button variant="plain" onPress={() => router.push('/conversation?demo=1')}>Preview sample conversation</Button>
    </View>
  </SafeAreaView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: tokens.color.butter },
  header: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 12, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  demo: { color: tokens.color.muted },
  content: { paddingHorizontal: 24, paddingTop: 28, paddingBottom: 20, flexGrow: 1 },
  title: { fontSize: 48, lineHeight: 51 },
  stage: { flex: 1, alignItems: 'center', justifyContent: 'center', marginVertical: 12 },
  oval: { position: 'absolute', width: '85%', height: '65%', maxHeight: 230, borderRadius: 130, backgroundColor: tokens.color.blue, transform: [{ rotate: '-8deg' }] },
  goose: { width: '90%', height: 290, maxHeight: '100%' },
  hello: { position: 'absolute', right: 0, top: 22, paddingHorizontal: 18, paddingVertical: 12, backgroundColor: tokens.color.paper, borderWidth: 1.5, borderColor: tokens.color.ink, borderRadius: 20, borderBottomLeftRadius: 4, transform: [{ rotate: '6deg' }] },
  description: { textAlign: 'center', fontSize: 23, lineHeight: 30 },
  actions: { paddingHorizontal: 24, paddingTop: 8, paddingBottom: 14, gap: 20 },
  note: { color: tokens.color.muted, textAlign: 'center' },
});
