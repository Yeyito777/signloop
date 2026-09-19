// RN 0.83's prebuilt-pod helpers pass unescaped filesystem paths to Ruby URI::File.
// Keep installs working when the checkout contains spaces (e.g. "htn 2026").
// Remove this patch after upgrading to an RN release that escapes these paths.
const fs = require('node:fs');
const path = require('node:path');
const root = path.dirname(require.resolve('react-native/package.json'));
const version = require(path.join(root, 'package.json')).version;
if (!version.startsWith('0.83.')) throw new Error('Review the React Native path patch before upgrading RN.');
for (const name of ['rncore.rb', 'rndependencies.rb']) {
  const file = path.join(root, 'scripts/cocoapods', name);
  const source = fs.readFileSync(file, 'utf8');
  const result = source.replaceAll('URI::File.build(path: destinationDebug)', 'URI::File.build(path: URI::DEFAULT_PARSER.escape(destinationDebug))');
  if (result !== source) fs.writeFileSync(file, result);
}

// Expo Constants has two related unquoted shell paths in SDK 55.
const constants = path.dirname(require.resolve('expo-constants/package.json'));
const podspec = path.join(constants, 'ios/EXConstants.podspec');
const podspecSource = fs.readFileSync(podspec, 'utf8');
const podspecResult = podspecSource.replace(
  /^    :script => .*get-app-config-ios\.sh.*,$/m,
  `    :script => 'bash -l "$PODS_TARGET_SRCROOT/../scripts/get-app-config-ios.sh"',`,
);
if (podspecResult !== podspecSource) fs.writeFileSync(podspec, podspecResult);
const script = path.join(constants, 'scripts/get-app-config-ios.sh');
const source = fs.readFileSync(script, 'utf8');
const result = source.replace('$(basename $PROJECT_DIR)', '$(basename "$PROJECT_DIR")');
if (result !== source) fs.writeFileSync(script, result);
