import { useEffect, useState } from 'react';
import { AppState, Platform, StyleSheet } from 'react-native';
import { requireOptionalNativeModule } from 'expo';
import { router } from 'expo-router';
import { useIsFocused } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Button, Copy } from '../ui/primitives';
import type { SignloopCamera as NativeView } from '../../modules/signloop-camera';
const Camera: typeof NativeView | null = Platform.OS === 'ios' && requireOptionalNativeModule('SignloopCamera')
  ? require('../../modules/signloop-camera').SignloopCamera : null;
export default function Expressions() {
  const focused = useIsFocused();
  const [foreground, setForeground] = useState(AppState.currentState === 'active');
  useEffect(() => { const sub = AppState.addEventListener('change', s => setForeground(s === 'active')); return () => sub.remove(); }, []);
  return <SafeAreaView style={{ flex: 1, backgroundColor: '#0D120F' }}>
    <Button variant="secondary" onPress={() => router.back()}>Back to conversation</Button>
    {Camera ? <Camera active={focused && foreground} captureId={1} labMode trackFace
      onStatus={() => {}} onClose={() => router.back()} style={styles.camera} />
      : <Copy>Expression lab requires the native iPhone build.</Copy>}
  </SafeAreaView>;
}
const styles = StyleSheet.create({ camera: { flex: 1 } });
