import 'react-native-url-polyfill/auto';
import { useEffect } from 'react';
import { AppState } from 'react-native';
import { disableVoiceUploads } from '../integrations/voiceSettings';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { BottomSheetModalProvider } from '@gorhom/bottom-sheet';
import { MotionProvider, motion } from '../ui/motion';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useFonts } from 'expo-font';
import * as SplashScreen from 'expo-splash-screen';
import { Fredoka_400Regular, Fredoka_500Medium } from '@expo-google-fonts/fredoka';
import { DMSans_400Regular, DMSans_500Medium, DMSans_600SemiBold } from '@expo-google-fonts/dm-sans';
import { SharedStageLayer, SharedStageProvider } from '../ui/SharedStage';
import { tokens } from '../ui/theme';
import { useReducedMotion } from '../ui/primitives';

void SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  useEffect(() => {
    const subscription = AppState.addEventListener('change', state => {
      if (state === 'background') disableVoiceUploads();
    });
    return () => subscription.remove();
  }, []);
  const [loaded, error] = useFonts({
    SignloopDisplayRegular: Fredoka_400Regular,
    SignloopDisplayMedium: Fredoka_500Medium,
    SignloopBodyRegular: DMSans_400Regular,
    SignloopBodyMedium: DMSans_500Medium,
    SignloopBodySemibold: DMSans_600SemiBold,
  });
  useEffect(() => { if (loaded || error) void SplashScreen.hideAsync(); }, [loaded, error]);
  if (!loaded && !error) return null;
  return <GestureHandlerRootView style={{ flex: 1 }}><MotionProvider><SharedStageProvider><BottomSheetModalProvider><Navigation /><SharedStageLayer /></BottomSheetModalProvider></SharedStageProvider></MotionProvider></GestureHandlerRootView>;
}

function Navigation() {
  const reducedMotion = useReducedMotion();
  return <>
    <StatusBar style="dark" />
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: tokens.color.butter }, animation: reducedMotion ? 'none' : 'fade', animationDuration: motion.navigation }}>
      <Stack.Screen name="index" />
      <Stack.Screen name="conversation" options={{ gestureEnabled: false }} />
      <Stack.Screen name="settings" />
    </Stack>
  </>;
}
