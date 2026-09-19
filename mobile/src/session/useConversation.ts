import { useCallback, useEffect, useReducer } from 'react';
import { AppState } from 'react-native';
import type { Framing, IntegrationKit } from '../integrations/contracts';
import { canCapture, initialSession, sessionReducer } from './model';

export function useConversation(kit: IntegrationKit) {
  const [state, dispatch] = useReducer(sessionReducer, undefined, initialSession);
  const captureActive = canCapture(state);

  useEffect(() => {
    if (!captureActive || state.framing !== 'ready') return;
    const captureId = state.captureId;
    return kit.translation.start(captureId, event => dispatch({ type: 'translation', event, captureId }));
  }, [captureActive, state.framing, state.captureId, kit]);

  useEffect(() => {
    if (!state.speech) return;
    const request = state.speech;
    const controller = new AbortController();
    kit.voice.speak(request.text, controller.signal).then(
      () => { if (!controller.signal.aborted) dispatch({ type: 'speech-ended', id: request.id }); },
      () => { if (!controller.signal.aborted) dispatch({ type: 'speech-ended', id: request.id, failed: true }); },
    );
    return () => controller.abort();
  }, [state.speech, kit]);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', next => {
      if (next !== 'active') dispatch({ type: 'pause' });
    });
    return () => subscription.remove();
  }, []);

  const onFraming = useCallback((framing: Framing, captureId: number) => {
    dispatch({ type: 'framing', framing, captureId });
  }, []);

  return { state, dispatch, captureActive, onFraming };
}
