import { useCallback, useEffect, useReducer, useState } from 'react';
import { AppState } from 'react-native';
import type { Framing, IntegrationKit } from '../integrations/contracts';
import { canCapture, initialSession, sessionReducer, type Action } from './model';

export function useConversation(kit: IntegrationKit) {
  const [state, send] = useReducer(sessionReducer, undefined, initialSession);
  const [demoAutoplay, setDemoAutoplay] = useState(true);
  const dispatch = useCallback((action: Action) => {
    if (kit.mode === 'demo') {
      if (action.type === 'demo-event' || action.type === 'demo-framing') setDemoAutoplay(false);
      if (action.type === 'retry' || action.type === 'sign-again' || action.type === 'resume') setDemoAutoplay(true);
    }
    send(action);
  }, [kit.mode]);
  const captureActive = canCapture(state);

  useEffect(() => {
    if (!captureActive || state.framing !== 'ready' || (kit.mode === 'demo' && !demoAutoplay)) return;
    const captureId = state.captureId;
    return kit.translation.start(captureId, event => {
      // A finite sample ends when accepted. Opening sheets must not replace a correction or manual demo state.
      if (kit.mode === 'demo' && event.type === 'accepted') setDemoAutoplay(false);
      dispatch({ type: 'translation', event, captureId });
    });
  }, [captureActive, state.framing, state.captureId, kit, demoAutoplay, dispatch]);

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
      // A camera permission prompt briefly makes iOS inactive; it is not an explicit pause.
      if (next === 'background') dispatch({ type: 'pause' });
    });
    return () => subscription.remove();
  }, []);

  const onFraming = useCallback((framing: Framing, captureId: number) => {
    dispatch({ type: 'framing', framing, captureId });
  }, []);

  return { state, dispatch, captureActive, onFraming };
}
