import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { GoosePreview } from './src/screens/GoosePreview';

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="dark" />
      <GoosePreview />
    </SafeAreaProvider>
  );
}
