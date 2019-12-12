Pod::Spec.new do |s|
  s.name         = "Sora"
  s.version      = "3.0.0"
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
  s.dependency "WebRTC", "79.5.0"
  s.dependency "Starscream", "3.1.1"
end
