/** Reserve the character independently of caption length or translation state. */
export function conversationLayout(availableHeight: number, fontScale: number) {
  const height = Math.max(0, availableHeight);
  // Larger system text gets more caption space, with scrolling for the full phrase.
  const caption = Math.min(height * 0.4, Math.max(height * 0.25, 156 * Math.max(1, fontScale)));
  const goose = height * 0.3;
  return { camera: height - caption - goose, goose, caption };
}
