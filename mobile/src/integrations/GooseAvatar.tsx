import { MrGoose } from '../../../goose/src/components/MrGoose';
import { SvgXml } from 'react-native-svg';
import type { AvatarProps } from './contracts';
import { gooseLipSync } from './lipSync';
import { goosePresentation } from './goosePresentation';
import { gooseSvg } from './demo-art';

/** One renderer identity and playback clock for Home, live capture, and UI demos. */
export function GooseAvatar({ mode, emotion, reducedMotion, style }: AvatarProps) {
  return <MrGoose {...goosePresentation(mode, emotion)} style={style}
    reducedMotion={reducedMotion} transparent lipSync={gooseLipSync}
    fallback={<SvgXml xml={gooseSvg} width="100%" height="100%" />} />;
}
