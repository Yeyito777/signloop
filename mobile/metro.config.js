const { getDefaultConfig } = require('expo/metro-config');
const path = require('node:path');

const config = getDefaultConfig(__dirname);
// The portable design system lives alongside this app (not in an npm workspace).
config.watchFolders = [path.resolve(__dirname, '../design-system'), path.resolve(__dirname, '../goose/src')];
// Reuse Sanvi's rendering sources, not its separate Expo 57/React runtime.
const gooseRoot = path.resolve(__dirname, '../goose') + path.sep;
config.resolver.resolveRequest = (context, name, platform) => {
  const sharedImport = context.originModulePath.startsWith(gooseRoot)
    && !name.startsWith('.') && !path.isAbsolute(name);
  return context.resolveRequest(sharedImport
    ? { ...context, originModulePath: path.join(__dirname, 'package.json') } : context, name, platform);
};
module.exports = config;
