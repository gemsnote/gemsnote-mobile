require 'xcodeproj'
abort 'Usage: create_project.rb <output-directory>' unless ARGV.length == 1
output = File.expand_path(ARGV.fetch(0))
run = ENV.fetch('OUTBOUND_SHARE_RUN')
abort 'Invalid run' unless run.match?(/\A[0-9a-f]{32}\z/)
project = Xcodeproj::Project.new(File.join(output, 'OutboundUI.xcodeproj'))
host = project.new_target(:application, 'ReceiverHost', :ios, '15.0')
receiver = project.new_target(:app_extension, 'ShareReceiver', :ios, '15.0')
test = project.new_target(:ui_test_bundle, 'OutboundUITests', :ios, '15.0')
{ host => 'Host.swift', receiver => 'ShareReceiver.swift', test => 'OutboundUITests.swift' }.each do |target, source|
  target.source_build_phase.add_file_reference(project.main_group.new_file(File.join(__dir__, source)))
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.github.gemsnote.#{target.name}",
      'TARGETED_DEVICE_FAMILY' => '1,2', 'CODE_SIGNING_ALLOWED' => 'NO',
    })
  end
end
host.build_configurations.each { |c| c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES' }
receiver.build_configurations.each do |c|
  c.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.github.gemsnote.ReceiverHost.ShareReceiver',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => File.join(output, 'Receiver-Info.plist'),
    'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'SKIP_INSTALL' => 'YES',
  })
end
Xcodeproj::Plist.write_to_path({
  'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
  'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
  'CFBundleName' => 'ShareReceiver', 'CFBundleDisplayName' => 'Gemsnote test receiver',
  'CFBundlePackageType' => 'XPC!', 'CFBundleInfoDictionaryVersion' => '6.0',
  'CFBundleVersion' => '1', 'CFBundleShortVersionString' => '1.0',
  'NSExtension' => {
    'NSExtensionPointIdentifier' => 'com.apple.share-services',
    'NSExtensionPrincipalClass' => '$(PRODUCT_MODULE_NAME).ShareReceiver',
    'NSExtensionAttributes' => { 'NSExtensionActivationRule' => {
      'NSExtensionActivationSupportsText' => true,
      'NSExtensionActivationSupportsFileWithMaxCount' => 1,
    } },
  },
}, File.join(output, 'Receiver-Info.plist'))
host.add_dependency(receiver)
embed = host.new_copy_files_build_phase('Embed Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(receiver.product_reference)
test.add_dependency(host)
test.build_configurations.each { |c| c.build_settings['TEST_TARGET_NAME'] = 'ReceiverHost' }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(test)
scheme.add_test_target(test)
scheme.test_action.build_configuration = 'Debug'
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'OUTBOUND_SHARE_RUN', value: run, enabled: true }
])
scheme.save_as(project.path, 'OutboundUITests')
