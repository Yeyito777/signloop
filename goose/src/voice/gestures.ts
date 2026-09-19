import { gooseGestures, type GooseGesture } from '../components/goose/motion.ts';
import { motion } from '../components/goose/settings.ts';

export type SpeechAlignment = {
  characters: string[];
  character_start_times_seconds: number[];
  character_end_times_seconds: number[];
};

export type SpokenWord = {
  word: string;
  start: number;
  end: number;
};

export type GestureCue = {
  name: GooseGesture;
  start: number;
  end: number;
};

const gestureWord = new Set<string>(gooseGestures);

function isGesture(word: string): word is GooseGesture {
  return gestureWord.has(word);
}

function lettersOnly(value: string): string {
  return value.toLowerCase().replace(/[^a-z]/g, '');
}

/** Skip the [happily] stage directions. Those are for the voice, not the wings. */
export function alignmentWithoutAudioTags(alignment: SpeechAlignment): SpeechAlignment {
  const characters: string[] = [];
  const character_start_times_seconds: number[] = [];
  const character_end_times_seconds: number[] = [];
  let inTag = false;

  for (let i = 0; i < alignment.characters.length; i += 1) {
    const raw = alignment.characters[i] ?? '';
    const start = alignment.character_start_times_seconds[i] ?? 0;
    const end = alignment.character_end_times_seconds[i] ?? start;
    if (raw.startsWith('[') && raw.endsWith(']') && raw.length > 1) continue;
    for (const mark of raw) {
      if (mark === '[') {
        inTag = true;
        continue;
      }
      if (mark === ']') {
        inTag = false;
        continue;
      }
      if (inTag) continue;
      characters.push(mark);
      character_start_times_seconds.push(start);
      character_end_times_seconds.push(end);
    }
  }

  return { characters, character_start_times_seconds, character_end_times_seconds };
}

/** Stitch timestamp chunks. If a chunk’s clock restarts at 0, slide it to follow the audio we already have. */
export function mergeAlignment(base: SpeechAlignment | undefined, next: SpeechAlignment | undefined, timeOffset: number): SpeechAlignment | undefined {
  if (!next?.characters.length) return base;
  const ends = base?.character_end_times_seconds;
  const lastEnd = ends?.[ends.length - 1] ?? 0;
  const firstStart = next.character_start_times_seconds[0] ?? 0;
  const offset = base && firstStart + 0.02 < lastEnd ? timeOffset : 0;
  const shifted: SpeechAlignment = {
    characters: next.characters,
    character_start_times_seconds: next.character_start_times_seconds.map(time => time + offset),
    character_end_times_seconds: next.character_end_times_seconds.map(time => time + offset),
  };
  if (!base) return shifted;
  return {
    characters: [...base.characters, ...shifted.characters],
    character_start_times_seconds: [...base.character_start_times_seconds, ...shifted.character_start_times_seconds],
    character_end_times_seconds: [...base.character_end_times_seconds, ...shifted.character_end_times_seconds],
  };
}

export function wordsFromAlignment(alignment: SpeechAlignment): SpokenWord[] {
  const words: SpokenWord[] = [];
  let current = '';
  let start = 0;
  let end = 0;

  const flush = () => {
    const word = lettersOnly(current);
    if (word) words.push({ word, start, end });
    current = '';
  };

  for (let i = 0; i < alignment.characters.length; i += 1) {
    const raw = alignment.characters[i] ?? '';
    const startTime = alignment.character_start_times_seconds[i] ?? 0;
    const endTime = alignment.character_end_times_seconds[i] ?? startTime;
    if (raw.length > 1 && /^[a-zA-Z]+$/.test(raw)) {
      flush();
      words.push({ word: raw.toLowerCase(), start: startTime, end: endTime });
      continue;
    }
    if (/[a-zA-Z]/.test(raw)) {
      if (!current) start = startTime;
      current += raw;
      end = endTime;
    } else {
      flush();
    }
  }
  flush();
  return words;
}

export function cuesFromWords(words: readonly SpokenWord[], duration = motion.gestureSeconds): GestureCue[] {
  return words.flatMap(word => (
    isGesture(word.word) ? [{ name: word.word, start: word.start, end: word.start + duration }] : []
  ));
}

export function cuesFromText(text: string, duration = motion.gestureSeconds): GestureCue[] {
  const words = text.toLowerCase().match(/[a-z]+/g) ?? [];
  const cues: GestureCue[] = [];
  let at = 0;
  for (const word of words) {
    if (!isGesture(word)) continue;
    cues.push({ name: word, start: at, end: at + duration });
    at += duration;
  }
  return cues;
}

export function gestureAt(cues: readonly GestureCue[] | undefined, time: number): { name: GooseGesture; localTime: number } | undefined {
  if (!cues?.length) return undefined;
  let match: GestureCue | undefined;
  for (const cue of cues) {
    if (time >= cue.start && time < cue.end) match = cue;
  }
  if (!match) return undefined;
  return { name: match.name, localTime: (time - match.start) / Math.max(0.001, match.end - match.start) };
}
