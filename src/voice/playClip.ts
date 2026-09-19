import { createAudioPlayer, setAudioModeAsync } from 'expo-audio';

export type ClipPlayback = {
  stop: () => void;
  currentTime: () => number;
};

export function unlockPlayback() {}

export async function playClip(uri: string, onEnded: () => void): Promise<ClipPlayback> {
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
    currentTime: () => player.currentTime,
  };
}
