Pod::Spec.new do |s|
  s.name         = "Sora"
  s.version      = "2.6.1"
  s.summary      = "Sora iOS SDK"
  s.description  = <<-DESC
                   A library to develop Sora client applications.
                   DESC
  s.homepage     = "https://github.com/shiguredo/sora-ios-sdk"
  s.license      = { :type => "Apache License, Version 2.0" }
  s.authors      = { "Shiguredo Inc." => "sora@shiguredo.jp" }
  s.platform     = :ios, "10.0"
  s.source       = {
      :git => "https://github.com/shiguredo/sora-ios-sdk.git",
      :tag => s.version
  }
  s.source_files  = "Sora/**/*.swift"
  s.frameworks = "SocketRocket"
  s.dependency "WebRTC", "78.8.1"
  s.dependency "SocketRocket", "0.5.1"
end
