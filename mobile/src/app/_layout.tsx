import { useEffect } from 'react';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useFonts } from 'expo-font';
import * as SplashScreen from 'expo-splash-screen';
import { Fredoka_400Regular, Fredoka_500Medium } from '@expo-google-fonts/fredoka';
import { DMSans_400Regular, DMSans_500Medium, DMSans_600SemiBold } from '@expo-google-fonts/dm-sans';
import { tokens } from '../ui/theme';
import { useReducedMotion } from '../ui/primitives';

void SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  const reducedMotion = useReducedMotion();
  const [loaded, error] = useFonts({
    SignloopDisplayRegular: Fredoka_400Regular,
    SignloopDisplayMedium: Fredoka_500Medium,
    SignloopBodyRegular: DMSans_400Regular,
    SignloopBodyMedium: DMSans_500Medium,
    SignloopBodySemibold: DMSans_600SemiBold,
  });
  useEffect(() => { if (loaded || error) void SplashScreen.hideAsync(); }, [loaded, error]);
  if (!loaded && !error) return null;
  return <>
    <StatusBar style="dark" />
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: tokens.color.butter }, animation: reducedMotion ? 'none' : 'slide_from_right' }}>
      <Stack.Screen name="index" />
      <Stack.Screen name="conversation" options={{ gestureEnabled: false }} />
    </Stack>
  </>;
}
