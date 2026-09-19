import { MrGoose } from '../../../goose/src/components/MrGoose';
import type { AvatarProps } from './contracts';
import { gooseLipSync } from './lipSync';

export function GooseAvatar({ mode, reducedMotion, style }: AvatarProps) {
  return <MrGoose style={style} animationEnabled={!reducedMotion}
    activity={mode === 'listening' ? 'watching' : mode}
    lipSync={gooseLipSync} />;
}
