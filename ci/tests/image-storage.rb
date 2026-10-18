#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'json'

class ImageStorageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('image-storage-', File.realpath(Dir.tmpdir))
    @storage = File.join(@directory, 'Build disk')
    FileUtils.mkdir_p(@storage)
    @environment = {'HOME' => @directory, 'RUNNER_TEMP' => File.join(@directory, 'runner'),
      'GITHUB_RUN_ID' => '123', 'GITHUB_RUN_ATTEMPT' => '1', 'IMAGE_STORAGE_DIRECTORY' => @storage}
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def shell(script, environment = {})
    Open3.capture3(@environment.merge(environment), 'bash', '-euc',
      'source ci/image-storage.sh; image_storage_paths; ' + script, chdir: ROOT)
  end

  def paths(environment = {})
    output, error, status = shell(
      'printf "%s\n" "$IMAGE_BUILD_WORKSPACE" "$IMAGE_ACCEPTANCE_WORKSPACE" "$IMAGE_CACHE_ROOT"', environment)
    assert status.success?, error
    output.lines.map(&:chomp)
  end

  def test_default_paths_are_preserved
    assert_equal ["#{@directory}/runner/offline-image", "#{@directory}/runner/acceptance-123-1",
      "#{@directory}/.cache/macos-image"], paths('IMAGE_STORAGE_DIRECTORY' => '')
  end

  def test_runs_are_isolated_while_parents_are_shared
    first = paths
    second = paths('GITHUB_RUN_ID' => '124')
    retry_paths = paths('GITHUB_RUN_ATTEMPT' => '2')
    assert first.all? { |path| path.start_with?(@storage + '/') }
    refute_equal first[0], second[0]
    refute_equal first[1], retry_paths[1]
    assert_equal first[2], second[2]
    assert_equal first[2], retry_paths[2]
  end

  def test_missing_volume_is_not_created
    missing = File.join(@directory, 'not-mounted')
    _, error, status = shell('true', 'IMAGE_STORAGE_DIRECTORY' => missing)
    refute status.success?
    assert_includes error, 'must already exist'
    refute File.exist?(missing)
  end

  def test_rejects_symlinked_storage_and_cache
    link = File.join(@directory, 'link')
    File.symlink(@storage, link)
    _, _, status = shell('true', 'IMAGE_STORAGE_DIRECTORY' => link)
    refute status.success?
    FileUtils.mkdir_p(File.join(@storage, 'macos-image'))
    File.symlink(@directory, File.join(@storage, 'macos-image/cache'))
    _, error, status = shell('image_storage_require_directory "$IMAGE_CACHE_ROOT/acceptance"')
    refute status.success?
    assert_includes error, 'symbolic link'
    refute File.exist?(File.join(@directory, 'acceptance'))
  end

  def test_cross_volume_move_is_rejected
    _, error, status = shell('image_storage_require_same_volume "$IMAGE_STORAGE_DIRECTORY" /dev')
    refute status.success?
    assert_includes error, 'same volume'
  end

  def test_sparse_clone_shares_volume_and_preserves_source
    build, _, cache = paths
    _, error, status = shell('image_storage_require_directory "$IMAGE_BUILD_WORKSPACE";
      image_storage_require_directory "$IMAGE_CACHE_ROOT/offline-parents";
      image_storage_require_same_volume "$IMAGE_BUILD_WORKSPACE" "$IMAGE_CACHE_ROOT/offline-parents"')
    assert status.success?, error
    source = File.join(cache, 'offline-parents/disk.img')
    File.open(source, 'w') { |file| file.write('parent'); file.truncate(1 << 30) }
    clone = File.join(build, 'disk.img')
    _, error, status = Open3.capture3('cp', '-c', source, clone)
    assert status.success?, error
    File.open(clone, 'r+') { |file| file.write('clone!') }
    assert_equal 'parent', File.binread(source, 6)
    assert_equal 'clone!', File.binread(clone, 6)
    assert_equal 1 << 30, File.size(clone)
    assert_operator File.stat(clone).blocks * 512, :<, 1 << 20
  end

  def prepare_cleanup(accepted: true)
    _, work, cache = paths
    reference = "ghcr.io/example/image@sha256:#{'a' * 64}"
    source = File.join(cache, "acceptance/#{'a' * 64}")
    %w[evidence runtime cloud tart download tools].each { |path| FileUtils.mkdir_p(File.join(work, path)) }
    FileUtils.mkdir_p(source)
    File.write(File.join(source, 'disk.img'), 'parent')
    File.write(File.join(work, 'cloud/publication.json'), JSON.generate(reference: reference))
    File.write(File.join(work, 'evidence/source-cache.txt'), source)
    File.write(File.join(work, 'evidence/acceptance.json'), '{}') if accepted
    [work, source]
  end

  def cleanup(work, keep: false)
    Open3.capture3(@environment.merge('ACCEPTANCE_WORKSPACE' => work,
      'KEEP_SOURCE_IMAGE' => keep.to_s), 'bash', 'ci/acceptance/cleanup.sh', chdir: ROOT)
  end

  def test_cleanup_removes_only_owned_images_and_preserves_evidence
    work, source = prepare_cleanup
    other = File.join(@storage, 'macos-image/runs/124-1/build')
    FileUtils.mkdir_p(other)
    _, error, status = cleanup(work)
    assert status.success?, error
    refute File.exist?(source)
    %w[tart download tools].each { |path| refute File.exist?(File.join(work, path)) }
    %w[evidence runtime cloud].each { |path| assert Dir.exist?(File.join(work, path)) }
    assert Dir.exist?(other)
  end

  def test_cleanup_keeps_parent_when_requested_or_acceptance_failed
    [true, false].each do |accepted|
      work, source = prepare_cleanup(accepted: accepted)
      FileUtils.rm_f(File.join(work, 'evidence/acceptance.json')) unless accepted
      _, error, status = cleanup(work, keep: accepted)
      assert status.success?, error
      assert_equal 'parent', File.read(File.join(source, 'disk.img'))
    end
  end

  def test_cleanup_rejects_a_foreign_cache_receipt
    work, source = prepare_cleanup
    File.write(File.join(work, 'evidence/source-cache.txt'), @storage)
    _, _, status = cleanup(work)
    refute status.success?
    assert File.exist?(File.join(source, 'disk.img'))
    assert Dir.exist?(File.join(work, 'tart'))
  end
end
