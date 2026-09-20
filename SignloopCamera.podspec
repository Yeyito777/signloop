# Rooted here so Expo and the standalone app compile the same temporal matcher.
Pod::Spec.new do |s|
  s.name = 'SignloopCamera'
  s.version = '1.0.0'
  s.summary = 'Honk & Tell on-device camera and MediaPipe preview for Expo'
  s.homepage = 'https://github.com/Yeyito777/signloop'
  s.license = { :type => 'Proprietary' }
  s.author = 'Honk & Tell team'
  s.source = { :git => 'https://github.com/Yeyito777/signloop.git' }
  s.platform = :ios, '17.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'MediaPipeTasksVision', '0.10.21'
  s.source_files = 'mobile/modules/signloop-camera/ios/*.swift',
    'ios/Signloop/{CameraPreview,CaptureLifecycle,CaptureCadence,CaptureFreshness,Recognition,SignSegmenter,Skeleton,SkeletonCameraTracker,SkeletonPipeline,BasicSignMatcher,BasicSignSegmentation,BasicLiveRecognition}.swift'
  # Private references are provisioned in Documents, never bundled for distribution.
  s.resource_bundles = { 'SignloopCameraModels' => ['ios/Signloop/Resources/hand_landmarker.task',
                                                    'ios/Signloop/Resources/pose_landmarker_lite.task'] }
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreML', 'QuartzCore', 'UIKit', 'Combine', 'SwiftUI'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  %w[hand_landmarker pose_landmarker_lite].each do |model|
    unless File.exist?(File.join(__dir__, "ios/Signloop/Resources/#{model}.task"))
      raise "Missing #{model}. Run npm run camera:assets from mobile/ before installing pods."
    end
  end
end
