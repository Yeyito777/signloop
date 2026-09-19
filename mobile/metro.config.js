const { getDefaultConfig } = require('expo/metro-config');
const path = require('node:path');

const config = getDefaultConfig(__dirname);
// The portable design system lives alongside this app (not in an npm workspace).
config.watchFolders = [path.resolve(__dirname, '../design-system')];
module.exports = config;
