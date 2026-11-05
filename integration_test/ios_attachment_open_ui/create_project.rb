require 'xcodeproj'
abort 'Usage: create_project.rb <output-directory>' unless ARGV.length == 1
output = File.expand_path(ARGV.fetch(0))
run = ENV.fetch('ATTACHMENT_OPEN_RUN')
abort 'Invalid run' unless run.match?(/\A[0-9a-f]{32}\z/)

project = Xcodeproj::Project.new(File.join(output, 'OpenUI.xcodeproj'))
host = project.new_target(:application, 'OpenReceiver', :ios, '15.0')
test = project.new_target(:ui_test_bundle, 'OpenUITests', :ios, '15.0')
{ host => 'Host.swift', test => 'OpenUITests.swift' }.each do |target, source|
  target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, source)))
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0', 'PRODUCT_BUNDLE_IDENTIFIER' => "com.github.gemsnote.#{target.name}",
      'TARGETED_DEVICE_FAMILY' => '1,2', 'CODE_SIGNING_ALLOWED' => 'NO',
    })
  end
end
host.build_configurations.each do |config|
  config.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'NO', 'INFOPLIST_FILE' => File.join(output, 'Host-Info.plist'),
  })
end
Xcodeproj::Plist.write_to_path({
  'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
  'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
  'CFBundleName' => 'OpenReceiver', 'CFBundleDisplayName' => 'OpenReceiver',
  'CFBundlePackageType' => 'APPL', 'CFBundleInfoDictionaryVersion' => '6.0',
  'CFBundleVersion' => '1', 'CFBundleShortVersionString' => '1.0',
  'UILaunchScreen' => {}, 'LSSupportsOpeningDocumentsInPlace' => true,
  'CFBundleDocumentTypes' => [{
    'CFBundleTypeName' => 'Test data', 'CFBundleTypeRole' => 'Editor',
    'LSHandlerRank' => 'Owner', 'LSItemContentTypes' => ['public.data'],
  }],
}, File.join(output, 'Host-Info.plist'))
test.add_dependency(host)
test.build_configurations.each do |config|
  config.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_TARGET_NAME' => 'OpenReceiver',
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.test_action.build_configuration = 'Debug'
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'ATTACHMENT_OPEN_RUN', value: run, enabled: true },
])
scheme.save_as(project.path, 'OpenUITests')
