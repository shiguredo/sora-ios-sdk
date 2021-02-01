Pod::Spec.new do |s|
  s.name         = "Sora"
  s.version      = "2020.7.1"
  s.summary      = "[Unofficial] Sora macOS SDK"
  s.description  = <<-DESC
                   A library to develop Sora client applications.
                   DESC
  s.license      = { :type => "Apache License, Version 2.0" }
  s.authors      = { "Shiguredo Inc." => "sora@shiguredo.jp" }
  s.platform     = :osx, "10.15"
  s.homepage     = "https://github.com/soudegesu/sora-macos-sdk"
  s.source       = {
      :git => "https://github.com/soudegesu/sora-macos-sdk.git",
      :tag => s.version
  }
  s.source_files  = "Sora/**/*.swift"
  s.resources = ['Sora/info.json']
  s.prepare_command = 'sh Sora/info.sh'
  s.dependency "WebRTC", '88.4324.3.1'
  s.dependency "Starscream", "3.1.1"
end
