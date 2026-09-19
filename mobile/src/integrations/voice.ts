import { fetchSpeech } from './speechTransport.ts';
import { playSpeechAudio } from './voicePlayback';
import { createVoiceAdapter } from './voiceLifecycle';
export const gooseVoice = createVoiceAdapter(fetchSpeech, playSpeechAudio);
