require 'xcodeproj'

abort 'Usage: ruby create_project.rb <output-directory>' unless ARGV.length == 1
run = ENV.fetch('FILE_PICKER_RUN')
abort 'Invalid run' unless run.match?(/\A[0-9a-f]{32}\z/)
output = File.expand_path(ARGV.fetch(0))
project = Xcodeproj::Project.new(File.join(output, 'PickerUI.xcodeproj'))
fixture = project.new_target(:application, 'PickerFiles', :ios, '15.0')
test = project.new_target(:ui_test_bundle, 'PickerUITests', :ios, '15.0')
{ fixture => 'Fixture.swift', test => 'PickerUITests.swift' }.each do |target, source|
  target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, source)))
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0',
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.github.gemsnote.#{target.name}",
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'CODE_SIGNING_ALLOWED' => 'NO',
    })
  end
end
fixture.build_configurations.each do |config|
  config.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => File.join(output, 'Fixture-Info.plist'),
  })
end
Xcodeproj::Plist.write_to_path({
  'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
  'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
  'CFBundleName' => 'PickerFiles',
  'CFBundleDisplayName' => 'PickerFiles',
  'CFBundlePackageType' => 'APPL',
  'CFBundleInfoDictionaryVersion' => '6.0',
  'CFBundleVersion' => '1',
  'CFBundleShortVersionString' => '1.0',
  'UIFileSharingEnabled' => true,
  'LSSupportsOpeningDocumentsInPlace' => true,
  'UILaunchScreen' => {},
}, File.join(output, 'Fixture-Info.plist'))
test.add_dependency(fixture)
test.build_configurations.each { |c| c.build_settings['TEST_TARGET_NAME'] = 'PickerFiles' }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(fixture)
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.test_action.build_configuration = 'Debug'
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'FILE_PICKER_RUN', value: run, enabled: true }
])
scheme.save_as(project.path, 'PickerUITests')
