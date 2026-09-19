import type { AvatarMode, Emotion } from './contracts';
import type { GooseActivity, GooseEmotion } from '../avatar/components/goose/motion';

const activities: Record<AvatarMode, GooseActivity> = {
  idle: 'idle', listening: 'watching', thinking: 'thinking', speaking: 'speaking',
};
const emotions: Record<Emotion, GooseEmotion | undefined> = {
  neutral: undefined, happy: 'joy', thoughtful: undefined,
  sadness: 'sadness', anger: 'anger', fear: 'fear',
};

/** Activity describes the app; emotion comes only from the accepted phrase. */
export function goosePresentation(mode: AvatarMode, emotion: Emotion) {
  return { activity: activities[mode], emotion: emotions[emotion] };
}
