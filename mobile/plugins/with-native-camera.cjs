const { withPodfileProperties, withXcodeProject } = require('expo/config-plugins');

module.exports = function withNativeCamera(config) {
  config = withPodfileProperties(config, config => {
    config.modResults['ios.deploymentTarget'] = '17.0';
    return config;
  });
  return withXcodeProject(config, config => {
    for (const value of Object.values(config.modResults.pbxXCBuildConfigurationSection())) {
      if (value.buildSettings?.IPHONEOS_DEPLOYMENT_TARGET) {
        value.buildSettings.IPHONEOS_DEPLOYMENT_TARGET = '17.0';
      }
    }
    return config;
  });
};
