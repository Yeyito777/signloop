import { createAudioPlayer, setAudioModeAsync } from 'expo-audio';

export function unlockPlayback() {}

export async function playClip(uri: string, onEnded: () => void): Promise<{ stop: () => void }> {
  await setAudioModeAsync({ playsInSilentMode: true });
  const player = createAudioPlayer({ uri });
  const subscription = player.addListener('playbackStatusUpdate', playback => {
    if (playback.error || playback.didJustFinish) onEnded();
  });
  player.play();
  return {
    stop: () => {
      subscription.remove();
      player.pause();
      player.remove();
    },
  };
}
