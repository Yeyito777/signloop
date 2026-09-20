const { withXcodeProject } = require('expo/config-plugins');

// The SDK 55 template executes an unquoted command-substitution result. Quote it
// so the React Native bundling script can live in a checkout containing spaces.
module.exports = config => withXcodeProject(config, mod => {
  const phases = mod.modResults.hash.project.objects.PBXShellScriptBuildPhase;
  for (const phase of Object.values(phases)) {
    if (!phase || typeof phase !== 'object' || !phase.shellScript) continue;
    const script = decodeShellScript(phase.shellScript);
    const fixed = script.replace(/^`[^\n]*react-native-xcode\.sh[^\n]*`$/m, line => `"${line}"`);
    if (fixed !== script) phase.shellScript = JSON.stringify(fixed);
  }
  return mod;
});

// Expo's in-memory generated phases can contain literal control characters
// inside a quoted PBX value; disk-parsed phases use JSON-style escapes.
function decodeShellScript(value) {
  if (!value.startsWith('"')) return value;
  return JSON.parse(value.replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t'));
}
module.exports.decodeShellScript = decodeShellScript;
