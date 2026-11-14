Pod::Spec.new do |s|
  s.name             = 'VisionForgeX'
  s.version          = '1.2.0'
  s.summary          = 'VisionForgeX SDK for iOS: Google Ad Manager demand with every decision made on the platform.'
  s.homepage         = 'https://apps.visionforgex.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'VisionForgeX' => 'support@visionforgex.com' }
  s.source           = { :git => 'https://github.com/VisionForgeX/visionforgex-ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.9'
  # CocoaPods builds the two folders as one module named VisionForgeX (Swift Package Manager keeps them apart).
  s.source_files     = 'Sources/**/*.swift'
  s.dependency 'Google-Mobile-Ads-SDK', '~> 13.12'
  s.dependency 'GoogleUserMessagingPlatform', '~> 2.7'
  s.static_framework = true
end
