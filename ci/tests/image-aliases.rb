#!/usr/bin/env ruby
require 'json'
require 'digest'

if %w[curl oras].include?(File.basename($PROGRAM_NAME))
  file = ENV.fetch('ALIAS_TEST_STATE')
  state = JSON.parse(File.read(file))
  output = ''
  if File.basename($PROGRAM_NAME) == 'oras'
    abort 'Unexpected registry mutation' unless ARGV[0] == 'tag' && ARGV[1] == state['reference']
    STDIN.read
    abort 'Registry refused tag update' if state['tagFails']
    state['tags'][ARGV[2]] = state['sourceManifest']
    state['retags'] << ARGV[2]
  elsif ARGV.last == 'https://ghcr.io/token'
    output = JSON.generate(token: 'anonymous-fixture')
  elsif ARGV.last.include?('/manifests/')
    tag = ARGV.last.split('/').last
    state['reads'] ||= {}
    state['reads'][tag] = state['reads'].fetch(tag, 0) + 1
    if state['raceTag'] == tag && state['reads'][tag] == 2
      state['tags'][tag] = state.fetch('raceManifest')
    end
    body = state['tags'][tag]
    File.write(ARGV[ARGV.index('--output') + 1], body || '{}')
    output = (state.fetch('errors', {})[tag] || (body ? 200 : 404)).to_s
  elsif ARGV.last.include?('/blobs/')
    File.write(ARGV[ARGV.index('--output') + 1], state.fetch('configs').fetch(ARGV.last.split('/').last))
  else
    abort 'Unexpected registry request'
  end
  File.write(file, JSON.generate(state))
  print output
  exit
end

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ImageAliasesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('image-aliases-')
    @directory = File.join(@root, '.local/share/macos-image/publications/accepted')
    @bin = File.join(@root, 'bin')
    FileUtils.mkdir_p([@directory, @bin, File.join(@root, 'ci'), File.join(@root, 'config/miso/test')])
    %w[publish-image-aliases.sh image-alias-order.jq].each do |file|
      FileUtils.cp(File.expand_path("../#{file}", __dir__), File.join(@root, 'ci', file))
    end
    %w[curl oras].each { |file| File.symlink(File.expand_path(__FILE__), File.join(@bin, file)) }
    @state = {'tags' => {}, 'configs' => {}, 'retags' => []}
    @acceptance = {'profile' => 'test', 'target' => {'version' => '26.7.3', 'build' => '25G342'},
      'variant' => 'xcode', 'prerelease' => false, 'reviewAccepted' => true,
      'xcodeConfiguration' => {'version' => '27.2'},
      'runtime' => {'exitCode' => 0, 'vmStopped' => true, 'sourceUnchanged' => true}}
    @environment = {'HOME' => @root, 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}",
      'LOCAL_PUBLICATION' => 'accepted', 'IMAGE_PROFILE' => 'test',
      'MISO_REGISTRY_USERNAME' => 'fixture', 'MISO_REGISTRY_PASSWORD' => 'fixture',
      'ALIAS_TEST_STATE' => File.join(@root, 'state.json')}
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def manifest(os, xcode = nil)
    labels = {'dev.macos-image.version' => os}
    labels['dev.macos-image.xcode-version'] = xcode if xcode
    config = JSON.generate(config: {Labels: labels})
    digest = "sha256:#{Digest::SHA256.hexdigest(config)}"
    @state['configs'][digest] = config
    JSON.generate(schemaVersion: 2, config: {digest: digest, size: config.bytesize})
  end

  def prepare
    target = @acceptance['target']
    xcode = @acceptance.dig('xcodeConfiguration', 'version')
    tag = @custom_tag || (xcode ? "#{target['version']}-xcode#{xcode}" : target['version'])
    variant = @acceptance['variant'] == 'xcode-slim' ? 'slim-xcode' : @acceptance['variant']
    source = manifest(target['version'], xcode)
    reference = "ghcr.io/minimillionaire/macos-fixture-#{variant}@sha256:#{Digest::SHA256.hexdigest(source)}"
    @state.merge!('reference' => reference, 'sourceManifest' => source)
    @state['tags'][tag] = @wrong_primary ? '{}' : source
    @acceptance['customTag'] = tag
    receipt = {status: 'published', reference: reference, tag: tag, acceptance: @acceptance,
      anonymousManifestVerified: true, anonymousConfigVerified: true}
    File.write(File.join(@directory, 'publication.json'), JSON.generate(receipt))
    File.write(File.join(@root, 'config/miso/test/profile.json'),
      JSON.generate(target: target, repository: 'ghcr.io/minimillionaire/macos-fixture'))
  end

  def publish(*arguments)
    prepare
    File.write(@environment['ALIAS_TEST_STATE'], JSON.generate(@state))
    output, status = Open3.capture2e(@environment, 'bash', File.join(@root, 'ci/publish-image-aliases.sh'), *arguments)
    @state = JSON.parse(File.read(@environment['ALIAS_TEST_STATE']))
    [status.success?, output]
  end

  def test_stable_xcode_creates_both_aliases_and_retry_is_idempotent
    success, output = publish
    assert success, output
    assert_equal %w[27.2 latest], @state['retags']
    assert_equal @state['sourceManifest'], @state['tags']['latest']
    @state['retags'] = []
    success, output = publish
    assert success, output
    assert_empty @state['retags']
  end

  def test_base_advances_latest_to_an_accepted_patch
    @acceptance['variant'] = 'base'
    @acceptance.delete('xcodeConfiguration')
    @state['tags']['latest'] = manifest('26.6.2')
    success, output = publish
    assert success, output
    assert_equal ['latest'], @state['retags']
  end

  def test_older_macos_cannot_roll_either_alias_back
    current = manifest('26.7.4', '27.2')
    @state['tags'].merge!('latest' => current, '27.2' => current)
    success, output = publish
    assert success, output
    assert_empty @state['retags']
    assert_equal current, @state['tags']['latest']
  end

  def test_older_compiler_only_advances_its_own_numeric_alias
    current = manifest('26.7.2', '27.3')
    @state['tags']['latest'] = current
    success, output = publish
    assert success, output
    assert_equal ['27.2'], @state['retags']
    assert_equal current, @state['tags']['latest']
  end

  def test_prereleases_and_custom_images_leave_stable_aliases_untouched
    @acceptance['prerelease'] = true
    success, output = publish
    assert success, output
    assert_empty @state['retags']
    @acceptance['prerelease'] = false
    @custom_tag = 'airbuild-runner'
    success, output = publish
    assert success, output
    assert_empty @state['retags']
  end

  def test_changed_version_binding_is_rejected_before_alias_mutation
    @wrong_primary = true
    success, = publish
    refute success
    assert_empty @state['retags']
  end

  def test_all_aliases_are_preflighted_before_any_write
    @state['errors'] = {'latest' => 503}
    success, = publish
    refute success
    assert_empty @state['retags']
  end

  def test_concurrent_alias_change_is_preserved
    @state['tags']['27.2'] = manifest('26.7.2', '27.2')
    @state['raceTag'] = '27.2'
    @state['raceManifest'] = manifest('26.7.4', '27.2')
    success, = publish
    refute success
    assert_empty @state['retags']
    assert_equal @state['raceManifest'], @state['tags']['27.2']
  end

  def test_registry_write_failure_does_not_record_success
    @state['tagFails'] = true
    success, = publish
    refute success
    assert_empty @state['retags']
    refute File.exist?(File.join(@directory, 'aliases.json'))
  end

  def test_unknown_identity_and_wrong_family_fail_closed
    [nil, '26.7.4-beta', '27.0'].each do |version|
      @state['tags']['latest'] = manifest(version, '27.2')
      success, = publish
      refute success
      assert_empty @state['retags']
    end
  end

  def test_trailing_zero_versions_are_equivalent_and_dry_run_does_not_write
    @state['tags']['latest'] = manifest('26.7.2', '27.2.0')
    success, output = publish('--check')
    assert success, output
    assert_empty @state['retags']
    success, output = publish
    assert success, output
    assert_equal %w[27.2 latest], @state['retags']
  end
end
