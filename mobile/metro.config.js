const { getDefaultConfig } = require('expo/metro-config');
const path = require('node:path');

const config = getDefaultConfig(__dirname);
// The portable design system lives alongside this app (not in an npm workspace).
config.watchFolders = [path.resolve(__dirname, '../design-system')];
// R3F's native entry uses require('three'). Three's CJS entry is a Node-only
// deprecation shim; resolve every consumer to the same browser/native ESM build.
config.resolver.resolveRequest = (context, moduleName, platform) => {
  if (moduleName === 'three') {
    return { type: 'sourceFile', filePath: path.resolve(__dirname, 'node_modules/three/build/three.module.js') };
  }
  return context.resolveRequest(context, moduleName, platform);
};
module.exports = config;
