#!/usr/bin/env ruby
require 'json'
require 'digest'

if %w[curl miso oras].include?(File.basename($PROGRAM_NAME))
  file = ENV.fetch('PUBLICATION_TEST_STATE')
  state = JSON.parse(File.read(file))
  tool = File.basename($PROGRAM_NAME)
  output = ''
  code = 0
  if tool == 'miso'
    state['uploads'] += 1
    if state['uploadFails']
      code = 1
    else
      state['exists'] = true
      state['manifest'] = state['newManifest'] if state['newManifest']
      output = JSON.generate(reference: "#{state['repository']}@#{state['digest']}")
      File.write(state['source'], 'changed') if state['changeSource']
    end
  elsif tool == 'oras'
    if ARGV[0] == 'resolve'
      output = state.fetch('aliases').fetch(ARGV[1].split(':').last)
    elsif ARGV[0] == 'tag'
      STDIN.read
      state['aliases'][ARGV[2]] = ARGV[1].split('@').last
      state['retags'] = state.fetch('retags', 0) + 1
    else
      abort "Unexpected oras command: #{ARGV.inspect}"
    end
  elsif ARGV.last == 'https://ghcr.io/token'
    output = JSON.generate(token: 'anonymous-fixture')
  elsif ARGV.last.include?('/manifests/')
    status = state['manifestError'] || (state['exists'] ? 200 : 404)
    body = state['wrongManifest'] && state['exists'] ? '{}' : state['manifest']
    File.write(ARGV[ARGV.index('--output') + 1], body)
    output = status.to_s
  elsif ARGV.last.include?('/blobs/')
    File.write(ARGV[ARGV.index('--output') + 1], state['badConfig'] ? 'corrupted' : state['config'])
  else
    abort "Unexpected #{tool} invocation"
  end
  File.write(file, JSON.generate(state))
  print output
  exit code
end

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'

class PublishLocalImageTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('local-publication-')
    @directory = File.join(@root, '.local/share/macos-image/publications/accepted')
    @source = File.join(@root, 'image')
    @bin = File.join(@root, 'bin')
    FileUtils.mkdir_p([@directory, @source, @bin, File.join(@root, 'ci'), File.join(@root, 'config/miso/test')])
    @script = File.join(@root, 'ci/publish-local-image.sh')
    FileUtils.cp(File.expand_path('../publish-local-image.sh', __dir__), @script)
    %w[shrink-image.sh disk-shrink.jq].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), File.join(@root, 'ci', name))
    end
    %w[curl miso oras].each { |name| File.symlink(File.expand_path(__FILE__), File.join(@bin, name)) }
    %w[disk.img nvram.bin config.json].each { |name| File.write(File.join(@source, name), 'fixture') }
    File.write(File.join(@source, 'config.json'), JSON.generate(os: 'darwin', diskFormat: 'raw'))
    File.truncate(File.join(@source, 'disk.img'), 50_000_003_072)
    disk_state, status = Open3.capture2('stat', '-f', '%i %z %.9Fm %.9Fc', File.join(@source, 'disk.img'))
    raise 'Cannot snapshot disk' unless status.success?
    shrink = {version: 1, beforeBytes: 160_000_000_000, minimumBytes: 40_000_000_000,
      reserveBytes: 8589934592, stepBytes: 10_000_000_000, targetBytes: 50_000_000_000,
      afterBytes: 50_000_003_072, diskState: disk_state.strip}
    File.write(File.join(@directory, 'disk-shrink.json'), JSON.generate(shrink))
    File.write(File.join(@directory, 'source-directory.txt'), @source)
    snapshot, status = Open3.capture2('stat', '-f', '%i %z %b %.9Fm %.9Fc', *%w[disk.img nvram.bin config.json].map { |name| File.join(@source, name) })
    raise 'Cannot snapshot fixture' unless status.success?
    File.write(File.join(@directory, 'source-state.txt'), snapshot)
    target = {version: '27.2', build: '26B123'}
    profile = {target: target, repository: 'ghcr.io/minimillionaire/macos-fixture'}
    File.write(File.join(@root, 'config/miso/test/profile.json'), JSON.generate(profile))
    xcode = {version: '27.2', build: '27B48'}
    File.write(File.join(@root, 'config/miso/test/xcode-27.2-rc.json'), JSON.generate(xcode))
    @record = {'target' => target, 'variant' => 'xcode-slim', 'customTag' => 'special',
      'misoVersion' => '0.5.18', 'prerelease' => true, 'reviewAccepted' => true,
      'diskShrink' => shrink,
      'runtime' => {'exitCode' => 0, 'vmStarted' => true, 'vmStopped' => true, 'sourceUnchanged' => true,
        'checks' => ['compile', 'runtime-startup', 'credential-rotation-before-cold-boot', 'credential-rotation-after-cold-boot']},
      'xcodeConfiguration' => xcode, 'componentInstallation' => {completed: true, method: 'xcodebuild', vmStopped: true, sourceUnchanged: true}}
    config = JSON.generate(architecture: 'arm64')
    manifest = JSON.generate(schemaVersion: 2, config: {digest: "sha256:#{Digest::SHA256.hexdigest(config)}", size: config.bytesize})
    @state = {'repository' => 'ghcr.io/minimillionaire/macos-fixture-slim-xcode', 'uploads' => 0,
      'manifest' => manifest, 'config' => config, 'digest' => "sha256:#{Digest::SHA256.hexdigest(manifest)}",
      'source' => File.join(@source, 'disk.img')}
    @environment = {'HOME' => @root, 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'LOCAL_PUBLICATION' => 'accepted',
      'IMAGE_PROFILE' => 'test', 'VARIANT' => 'xcode', 'XCODE_VERSION' => '27.2-rc', 'XCODE_FLAVOR' => 'slim',
      'MISO_VERSION' => '0.5.18', 'MISO_REGISTRY_USERNAME' => 'fixture', 'MISO_REGISTRY_PASSWORD' => 'fixture',
      'GITHUB_RUN_ID' => '123', 'GITHUB_RUN_ATTEMPT' => '1', 'GITHUB_SHA' => 'fixture', 'RUNNER_TEMP' => @root,
      'GITHUB_STEP_SUMMARY' => File.join(@root, 'summary'), 'PUBLICATION_TEST_STATE' => File.join(@root, 'state.json')}
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def publish
    File.write(File.join(@directory, 'acceptance.json'), JSON.generate(@record))
    File.write(@environment['PUBLICATION_TEST_STATE'], JSON.generate(@state))
    log, status = Open3.capture2e(@environment, 'bash', @script)
    @state = JSON.parse(File.read(@environment['PUBLICATION_TEST_STATE']))
    [status.success?, log]
  end

  def assert_rejected
    success, log = publish
    refute success, log
    assert_equal 0, @state['uploads'], log
    refute File.exist?(File.join(@directory, 'publication.json'))
  end

  def test_failed_or_incomplete_acceptance_never_uploads
    [['exitCode', 1], ['vmStopped', false], ['sourceUnchanged', false]].each do |key, value|
      previous = @record['runtime'][key]
      @record['runtime'][key] = value
      assert_rejected
      @record['runtime'][key] = previous
    end
    @record['reviewAccepted'] = false
    assert_rejected
  end

  def test_wrong_target_or_xcode_build_never_uploads
    @record['target'] = {version: '27.2', build: '26B118'}
    assert_rejected
    @record['target'] = {version: '27.2', build: '26B123'}
    @record['xcodeConfiguration'] = {version: '27.2', build: '27B99'}
    assert_rejected
  end

  def test_changed_or_replaced_source_never_uploads
    File.write(File.join(@source, 'disk.img'), 'modified image')
    assert_rejected
  end

  def test_existing_tag_and_registry_failure_never_upload
    @state['exists'] = true
    assert_rejected
    @state['manifestError'] = 403
    @environment['GITHUB_RUN_ATTEMPT'] = '2'
    assert_rejected
  end

  def test_upload_failure_preserves_source_without_completion
    @state['uploadFails'] = true
    success, = publish
    refute success
    assert_equal 'fixture', File.binread(File.join(@source, 'disk.img'), 7)
    assert_equal 50_000_003_072, File.size(File.join(@source, 'disk.img'))
    refute File.exist?(File.join(@directory, 'publication.json'))
  end

  def test_verified_publication_is_idempotent
    success, log = publish
    assert success, log
    receipt = JSON.parse(File.read(File.join(@directory, 'publication.json')))
    assert_equal "#{@state['repository']}@#{@state['digest']}", receipt['reference']
    assert receipt['anonymousManifestVerified']
    assert receipt['anonymousConfigVerified']
    @environment['GITHUB_RUN_ATTEMPT'] = '2'
    success, log = publish
    assert success, log
    assert_equal 1, @state['uploads']
  end

  def test_config_verification_can_resume_without_reupload
    @state['badConfig'] = true
    success, = publish
    refute success
    refute File.exist?(File.join(@directory, 'publication.json'))
    @state['badConfig'] = false
    @environment['GITHUB_RUN_ATTEMPT'] = '2'
    success, log = publish
    assert success, log
    assert_equal 1, @state['uploads']
  end

  def test_mismatched_published_manifest_is_not_completion
    @state['wrongManifest'] = true
    success, = publish
    refute success
    refute File.exist?(File.join(@directory, 'publication.json'))
  end

  def test_mutation_during_upload_is_not_completion
    @state['changeSource'] = true
    success, = publish
    refute success
    refute File.exist?(File.join(@directory, 'publication.json'))
  end

  def test_missing_shrink_receipt_or_pre_shrink_acceptance_never_uploads
    @record.delete('diskShrink')
    assert_rejected
    File.unlink(File.join(@directory, 'disk-shrink.json'))
    assert_rejected
  end

  def test_only_explicit_exact_digest_replacement_is_allowed
    @state['exists'] = true
    @state['newManifest'] = @state['manifest']
    @state['manifest'] = JSON.generate(schemaVersion: 2, old: true)
    @record['replacesReference'] = "#{@state['repository']}@sha256:#{Digest::SHA256.hexdigest(@state['manifest'])}"
    assert_rejected
    @environment['REPLACE_EXISTING'] = 'true'
    @environment['GITHUB_RUN_ATTEMPT'] = '2'
    success, log = publish
    assert success, log
    assert_equal 1, @state['uploads']
  end

  def test_replacement_refuses_a_tag_changed_since_acceptance
    @state['exists'] = true
    @record['replacesReference'] = "#{@state['repository']}@sha256:#{'a' * 64}"
    @environment['REPLACE_EXISTING'] = 'true'
    assert_rejected
  end

  def test_aliases_share_one_upload_and_resume_without_retagging
    @state['exists'] = true
    @state['newManifest'] = @state['manifest']
    @state['manifest'] = JSON.generate(schemaVersion: 2, old: true)
    previous = "sha256:#{Digest::SHA256.hexdigest(@state['manifest'])}"
    @state['aliases'] = {'special-rc' => previous}
    @record['replacesReference'] = "#{@state['repository']}@#{previous}"
    @record['additionalTags'] = ['special-rc']
    @environment['REPLACE_EXISTING'] = 'true'
    success, log = publish
    assert success, log
    assert_equal @state['digest'], @state['aliases']['special-rc']
    assert_equal 1, @state['uploads']
    @environment['GITHUB_RUN_ATTEMPT'] = '2'
    success, log = publish
    assert success, log
    assert_equal 1, @state['uploads']
    assert_equal 1, @state['retags']
  end

  def test_foreign_alias_is_not_replaced_or_reported_complete
    @state['exists'] = true
    @state['newManifest'] = @state['manifest']
    @state['manifest'] = JSON.generate(schemaVersion: 2, old: true)
    @record['replacesReference'] = "#{@state['repository']}@sha256:#{Digest::SHA256.hexdigest(@state['manifest'])}"
    @record['additionalTags'] = ['special-rc']
    @state['aliases'] = {'special-rc' => "sha256:#{'f' * 64}"}
    @environment['REPLACE_EXISTING'] = 'true'
    success, = publish
    refute success
    assert_equal "sha256:#{'f' * 64}", @state['aliases']['special-rc']
    assert_nil @state['retags']
    refute File.exist?(File.join(@directory, 'publication.json'))
  end

  def test_legacy_disk_only_replacement_requires_fresh_runtime_and_credentials_checks
    @state['exists'] = true
    @state['newManifest'] = @state['manifest']
    @state['manifest'] = JSON.generate(schemaVersion: 2, old: true)
    @record['replacesReference'] = "#{@state['repository']}@sha256:#{Digest::SHA256.hexdigest(@state['manifest'])}"
    @record['parentReference'] = @record['replacesReference']
    @record['transformation'] = 'disk-shrink'
    @record['constructionVMStarted'] = false
    @record['componentInstallation'] = nil
    @environment['REPLACE_EXISTING'] = 'true'
    %w[runtime-startup credential-rotation-before-cold-boot credential-rotation-after-cold-boot].each do |check|
      @record['runtime']['checks'].delete(check)
      assert_rejected
      @record['runtime']['checks'] << check
    end
    @record.delete('transformation')
    assert_rejected
    @record['transformation'] = 'disk-shrink'
    success, log = publish
    assert success, log
    assert_equal 1, @state['uploads']
  end
end
