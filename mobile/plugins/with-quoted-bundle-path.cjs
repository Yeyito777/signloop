const { withXcodeProject } = require('expo/config-plugins');

// The SDK 55 template executes an unquoted command-substitution result. Quote it
// so the React Native bundling script can live in a checkout containing spaces.
module.exports = config => withXcodeProject(config, mod => {
  const phases = mod.modResults.hash.project.objects.PBXShellScriptBuildPhase;
  for (const phase of Object.values(phases)) {
    if (!phase || typeof phase !== 'object' || !phase.shellScript) continue;
    const script = JSON.parse(phase.shellScript);
    const fixed = script.replace(/^`[^\n]*react-native-xcode\.sh[^\n]*`$/m, line => `"${line}"`);
    if (fixed !== script) phase.shellScript = JSON.stringify(fixed);
  }
  return mod;
});
