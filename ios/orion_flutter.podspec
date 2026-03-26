Pod::Spec.new do |s|
  s.name             = 'orion_flutter'
  s.version          = '1.0.23'
  s.summary          = 'Orion Flutter SDK — Real User Monitoring for Flutter apps.'
  s.description      = <<-DESC
    Orion Flutter SDK tracks screen performance (TTID/TTFD), frame metrics,
    battery drain, memory growth, wake lock timing, rage clicks, and network
    requests for Flutter applications on iOS.
  DESC

  s.homepage         = 'https://github.com/epsilondelta-speed/orion-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Epsilon Delta' => 'support@epsilondelta.co' }
  s.source           = { :path => '.' }

  # All Swift source files in ios/Classes/
  s.source_files     = 'Classes/**/*.swift'

  # Minimum iOS version — UIDevice.batteryLevel available from iOS 9,
  # NWPathMonitor from iOS 12, CryptoKit SHA-256 from iOS 13.
  # Flutter itself requires iOS 12+, so iOS 13 is a safe floor.
  s.ios.deployment_target = '13.0'

  # Swift version
  s.swift_version    = '5.0'

  # iOS system frameworks used
  s.frameworks       = 'UIKit', 'Foundation', 'Network', 'CryptoKit'

  # Required for zlib (GZIP compression used in SendData.swift)
  s.library          = 'z'

  # Flutter dependency
  s.dependency 'Flutter'
end
