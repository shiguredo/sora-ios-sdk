Pod::Spec.new do |s|
  s.name         = "Sora"
  s.version      = "2020.7"
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
  s.resources = ['Sora/info.json', 'Sora/*.xib']
  s.prepare_command = 'sh Sora/info.sh'
  s.dependency "WebRTC", '86.4240.10.0'
  s.dependency "Starscream", "3.1.1"
end
