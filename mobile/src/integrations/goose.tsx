import { MrGoose } from '../avatar/components/MrGoose';
import type { AvatarProps } from './contracts';
import { goosePresentation } from './goosePresentation';

/** One renderer identity for Home, the native camera, and the explicit UI demo. */
export function GooseAvatar({ mode, emotion, reducedMotion, style }: AvatarProps) {
  return <MrGoose {...goosePresentation(mode, emotion)} reducedMotion={reducedMotion} style={style} />;
}
