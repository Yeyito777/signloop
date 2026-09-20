/** Shared vocabulary for expression matching, character poses and speech delivery. */
export const emotions = ['neutral', 'joy', 'sadness', 'anger', 'fear', 'disgust'] as const;
export type Emotion = typeof emotions[number];
export function isEmotion(value: unknown): value is Emotion {
  return typeof value === 'string' && (emotions as readonly string[]).includes(value);
}
