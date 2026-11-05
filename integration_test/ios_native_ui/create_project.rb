require 'xcodeproj'

abort 'Usage: ruby create_project.rb <output-directory>' unless ARGV.length == 1
output = File.expand_path(ARGV.fetch(0))
project = Xcodeproj::Project.new(File.join(output, 'SharingUI.xcodeproj'))
target = project.new_target(:ui_test_bundle, 'SharingUITests', :ios, '15.0')
source = project.main_group.new_file(File.join(__dir__, 'SharingUITests.swift'))
target.source_build_phase.add_file_reference(source)
target.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.github.gemsnote.SharingUITests'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
end
fixture = project.new_target(:application, 'SharingFixture', :ios, '15.0')
fixture.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, 'SharingFixture.swift')))
fixture.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.github.gemsnote.SharingFixture'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
end
target.add_dependency(fixture)
target.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = 'SharingFixture'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(fixture)
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.test_action.build_configuration = 'Debug'
restore_language = ENV.fetch('GEMSNOTE_RESTORE_LANGUAGE', 'system')
abort 'Invalid restore language' unless %w[system zh en].include?(restore_language)
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'GEMSNOTE_RESTORE_LANGUAGE', value: restore_language, enabled: true }
])
scheme.save_as(project.path, 'SharingUITests')
