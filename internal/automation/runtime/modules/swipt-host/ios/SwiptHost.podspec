Pod::Spec.new do |s|
  s.name           = 'SwiptHost'
  s.version        = '1.0.0'
  s.summary        = 'Connects swiplet interfaces to Swipt'
  s.license        = 'GPL-3.0-or-later'
  s.author         = 'Swipt'
  s.homepage       = 'https://github.com/swipt-automation/swipt'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = '**/*.swift'
end
