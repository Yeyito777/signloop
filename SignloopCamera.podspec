# Rooted here so Expo compiles its gesture tracker directly from ios/Signloop/.
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
    'ios/Signloop/{CameraPreview,CaptureLifecycle,CaptureCadence,CaptureFreshness,Recognition,SignSegmenter,Skeleton,SkeletonPipeline,SkeletonCameraTracker,SkeletonOverlay,BasicSignMatcher,BasicSignSegmentation,BasicLiveRecognition,AlphabetRecognition,ExpressionMeasurements,ExpressionCues,ExpressionTeacher,TaughtExpressionProfile,ExpressionTesterView}.swift'
  # Only redistributable tracker/alphabet assets. The private word bank is
  # generated per researcher and provisioned separately into Documents.
  s.resource_bundles = { 'SignloopCameraModels' => ['ios/Signloop/Resources/{hand_landmarker,pose_landmarker_lite,face_landmarker}.task',
                                                   'ios/Signloop/Resources/alphabet-static.json',
                                                   'ios/Signloop/Resources/alphabet-license.txt'] }
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Accelerate', 'QuartzCore', 'UIKit', 'Combine', 'SwiftUI'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  unless %w[hand_landmarker.task pose_landmarker_lite.task face_landmarker.task alphabet-static.json].all? { |f| File.exist?(File.join(__dir__, 'ios/Signloop/Resources', f)) }
    raise 'Missing detector models. Run npm run camera:assets from mobile/ before installing pods.'
  end
end
