import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

/** Touches pass through the decorative canvas to this character-sized target. */
export function GoosePressTarget({ onPress, playing, disabled = false }: {
  onPress: () => void;
  playing: boolean;
  disabled?: boolean;
}) {
  const [size, setSize] = useState({ width: 0, height: 0 });
  // Match the scene's orthographic framing, leaving the surrounding stage untappable.
  const zoom = Math.min(size.width / 2.8, size.height / 4.2);
  const width = zoom * 2.35;
  const height = zoom * 3.9;
  return <View pointerEvents="box-none" style={StyleSheet.absoluteFill}
    onLayout={({ nativeEvent }) => setSize({ width: nativeEvent.layout.width, height: nativeEvent.layout.height })}>
    <Pressable onPress={onPress} disabled={disabled}
      accessibilityRole="button" accessibilityLabel={playing ? 'Mr. Goose, stop dancing' : 'Mr. Goose, dance'}
      accessibilityHint={playing ? 'Tap the goose again to stop the dance.' : 'Tap the goose to make him dance.'}
      accessibilityState={{ disabled }}
      style={{ position: 'absolute', width, height, left: (size.width - width) / 2, top: (size.height - height) / 2, borderRadius: width / 2 }} />
  </View>;
}
