const { getDefaultConfig } = require('expo/metro-config');
const path = require('node:path');

const config = getDefaultConfig(__dirname);
config.watchFolders = [path.resolve(__dirname, '../design-system'), path.resolve(__dirname, '../goose/src')];
// Share Sanvi's character sources while keeping the app on its Expo 55 runtime.
const gooseRoot = path.resolve(__dirname, '../goose') + path.sep;
config.resolver.resolveRequest = (context, name, platform) => {
  // Three's CJS entry calls Node-only process.emitWarning. All consumers must
  // use one ESM instance, including Fiber's native renderer and shared sources.
  if (name === 'three') {
    return { type: 'sourceFile', filePath: path.resolve(__dirname, 'node_modules/three/build/three.module.js') };
  }
  const sharedImport = context.originModulePath.startsWith(gooseRoot)
    && !name.startsWith('.') && !path.isAbsolute(name);
  return context.resolveRequest(sharedImport
    ? { ...context, originModulePath: path.join(__dirname, 'package.json') } : context, name, platform);
};
module.exports = config;
