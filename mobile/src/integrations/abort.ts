/** RN's AbortController polyfill does not implement AbortSignal.throwIfAborted. */
export function assertNotAborted(signal: AbortSignal) {
  if (signal.aborted) throw new Error('Operation cancelled.');
}
