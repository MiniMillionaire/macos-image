#!/usr/bin/env ruby
require 'minitest/autorun'
require 'json'
require 'open3'

class RuntimeInventoryTest < Minitest::Test
  FILTER = File.expand_path('../acceptance/helpers/runtime-inventory.jq', __dir__)

  def setup
    @identifier = 'com.apple.CoreSimulator.SimRuntime.iOS-27-1'
    @requirements = {'runtimes' => [{'platform' => 'iOS', 'version' => '27.1', 'build' => '24A94232'}]}
    @image = {'runtimeIdentifier' => @identifier, 'version' => '27.1', 'build' => '24A94232',
      'state' => 'Ready', 'kind' => 'Patchable Cryptex Disk Image', 'signatureState' => 'Unknown'}
    @images = {'first' => @image}
    @runtime = {'identifier' => @identifier, 'version' => '27.1', 'buildversion' => '24A94232',
      'isAvailable' => true, 'bundlePath' => '/Library/Developer/CoreSimulator/Volumes/iOS/runtime.simruntime'}
    @runtimes = {'runtimes' => [@runtime]}
  end

  def validate
    Open3.capture3('jq', '-e', '--argjson', 'requirements', JSON.generate([@requirements]),
      '--argjson', 'images', JSON.generate([@images]), '-f', FILTER, stdin_data: JSON.generate(@runtimes))
  end

  def test_native_cryptex_with_unknown_signature_state_is_usable
    output, error, status = validate
    assert status.success?, error
    assert_equal @runtime['bundlePath'], JSON.parse(output).first['bundlePath']
  end

  def test_duplicate_dmg_and_cryptex_fail_even_with_one_available_runtime
    @images['second'] = @image.merge('kind' => 'Disk Image')
    _, error, status = validate
    refute status.success?
    assert_includes error, 'duplicate'
  end

  def test_wrong_build_missing_runtime_and_unavailable_mount_fail
    [-> { @image['build'] = '24A434' }, -> { @images.clear },
      -> { @runtime['isAvailable'] = false }, -> { @image['state'] = 'Unusable' },
      -> { @runtime['bundlePath'] = nil }].each do |mutation|
      setup
      mutation.call
      _, _, status = validate
      refute status.success?
    end
  end

  def test_path_replacement_changes_the_stability_snapshot
    initial, _, first = validate
    @runtime['bundlePath'] = '/Library/Developer/CoreSimulator/Cryptex/new/runtime.simruntime'
    current, _, second = validate
    assert first.success?
    assert second.success?
    refute_equal JSON.parse(initial), JSON.parse(current)
  end

  def test_visionos_uses_the_xros_runtime_identifier
    @requirements['runtimes'][0]['platform'] = 'visionOS'
    @image['runtimeIdentifier'] = @runtime['identifier'] = 'com.apple.CoreSimulator.SimRuntime.xrOS-27-1'
    _, error, status = validate
    assert status.success?, error
  end
  def removals
    Open3.capture3('jq', '-e', '--argjson', 'requirements', JSON.generate([@requirements]),
      '-f', File.expand_path('../xcode-runtime-removals.jq', __dir__), stdin_data: JSON.generate(@images))
  end

  def test_component_retry_keeps_the_native_runtime_and_removes_legacy_installations
    output, error, status = removals
    assert status.success?, error
    assert_empty JSON.parse(output)
    @image['kind'] = 'Legacy Download'
    @image['deletable'] = true
    output, error, status = removals
    assert status.success?, error
    assert_equal [@image], JSON.parse(output)
  end

  def test_duplicate_installations_are_both_replaced_but_undeletable_ones_fail_closed
    @image['deletable'] = true
    @images['second'] = @image.merge('kind' => 'Disk Image')
    output, error, status = removals
    assert status.success?, error
    assert_equal 2, JSON.parse(output).length
    @image['deletable'] = false
    _, _, status = removals
    refute status.success?
  end

end
