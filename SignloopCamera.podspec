# Rooted here so Expo and the standalone iOS app compile the SAME scanner sources.
Pod::Spec.new do |s|
  s.name = 'SignloopCamera'
  s.version = '1.0.0'
  s.summary = 'Signloop on-device camera and MediaPipe preview for Expo'
  s.homepage = 'https://github.com/Yeyito777/signloop'
  s.license = { :type => 'Proprietary' }
  s.author = 'Signloop team'
  s.source = { :git => 'https://github.com/Yeyito777/signloop.git' }
  s.platform = :ios, '17.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'MediaPipeTasksVision', '0.10.21'
  s.source_files = 'mobile/modules/signloop-camera/ios/*.swift',
    'ios/Signloop/{CameraTracker,CameraPreview,CaptureLifecycle,CaptureCadence,CaptureFreshness,Recognition,SignEngine,SignEngineFeatures,SignSegmenter}.swift'
  # The optional SignEngine package (Core ML + policy.json + manifest.json, produced by
  # recognition/export_coreml.py) rides along only if present; the app runs without it.
  s.resource_bundles = { 'SignloopCameraModels' => ['ios/Signloop/Resources/gesture_recognizer.task',
                                                    'ios/Signloop/Resources/SignEngine/**/*'] }
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreML', 'QuartzCore', 'UIKit', 'Combine', 'SwiftUI'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  unless File.exist?(File.join(__dir__, 'ios/Signloop/Resources/gesture_recognizer.task'))
    raise 'Missing hand model. Run npm run camera:assets from mobile/ before installing pods.'
  end
end
