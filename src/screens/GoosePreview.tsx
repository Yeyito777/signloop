import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { MrGoose } from '../components/MrGoose';
import { colors } from '../components/goose/settings';
import { useMotionPreferences } from '../hooks/useMotionPreferences';

export function GoosePreview() {
  const [animationEnabled, setAnimationEnabled] = useState(true);
  const { reducedMotion } = useMotionPreferences();
  return (
    <SafeAreaView style={styles.screen}>
      <View style={styles.heading}>
        <View style={styles.eyebrow}><View style={styles.dot} /><Text style={styles.eyebrowText}>SIGNLOOP</Text></View>
        <Text accessibilityRole="header" style={styles.title}>Mr. Goose</Text>
      </View>
      <MrGoose animationEnabled={animationEnabled} style={styles.goose} />
      <View style={styles.controls}>
        <Text style={styles.caption}>Your sign language companion.</Text>
        <Pressable accessibilityRole="button"
          accessibilityLabel={animationEnabled ? 'Pause animation' : 'Resume animation'}
          accessibilityHint={reducedMotion ? 'Reduce Motion is on. Mr. Goose will remain still.' : 'Changes Mr. Goose’s gentle idle motion.'}
          onPress={() => setAnimationEnabled(value => !value)}
          style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}>
          <Text style={styles.buttonIcon} accessible={false}>{animationEnabled ? 'Ⅱ' : '▷'}</Text>
          <Text style={styles.buttonText}>{animationEnabled ? 'Pause animation' : 'Resume animation'}</Text>
        </Pressable>
        <Text style={styles.note} accessibilityLiveRegion="polite">
          {reducedMotion ? 'Keeping still · Reduce Motion is on' : animationEnabled ? 'Just taking it slow.' : 'Taking a little breather.'}
        </Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  heading: { alignItems: 'center', paddingTop: 26, paddingHorizontal: 24 },
  eyebrow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 14 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#788775' },
  eyebrowText: { color: '#6D7668', fontSize: 10, fontWeight: '700', letterSpacing: 2.2 },
  title: { fontSize: 43, fontWeight: '700', letterSpacing: -1.8, color: '#30372F' },
  goose: { flex: 1, minHeight: 160 },
  controls: { alignItems: 'center', paddingHorizontal: 24, paddingBottom: 20 },
  caption: { color: '#817D72', fontSize: 13, marginBottom: 23 },
  button: { minHeight: 56, width: '100%', maxWidth: 310, borderRadius: 28, backgroundColor: '#394738', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 11, padding: 16 },
  buttonPressed: { backgroundColor: '#53634D' },
  buttonIcon: { color: '#FFFDF5', fontSize: 19, fontWeight: '600' },
  buttonText: { color: '#FFFDF5', fontSize: 15, fontWeight: '600' },
  note: { color: '#8C887D', fontSize: 11, marginTop: 14, textAlign: 'center' },
});
