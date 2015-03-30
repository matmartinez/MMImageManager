Pod::Spec.new do |s|
  s.name         = "MMImageManager"
  s.version      = "0.0.6"
  s.summary      = "Image caching for the rest of us."
  s.homepage     = "http://www.matmartinez.net/"
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { "Matías Martínez" => "soy@matmartinez.net" }
  s.source       = { :git => "https://github.com/matmartinez/MMImageManager.git", :tag => s.version.to_s }
  s.platform     = :ios, '7.0'
  s.framework  = 'QuartzCore'
  s.requires_arc = true
  s.source_files = 'Classes/*.{h,m}'
 end