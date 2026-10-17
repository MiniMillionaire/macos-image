#!/usr/bin/env ruby
require 'json'

if %w[gh oras].include?(File.basename($PROGRAM_NAME))
  file = ENV.fetch('CLEANUP_TEST_STATE')
  state = JSON.parse(File.read(file))
  versions = state.fetch('versions')
  output = ''
  tool = File.basename($PROGRAM_NAME)
  if tool == 'gh' && ARGV[0, 2] == ['api', '--paginate']
    output = JSON.generate(versions)
  elsif tool == 'gh' && ARGV[0, 3] == ['api', '--method', 'DELETE']
    id = Integer(ARGV[3].split('/').last)
    state['deleted'] << id
    versions.reject! { |version| version['id'] == id }
  elsif tool == 'oras' && ARGV[0] == 'login'
    STDIN.read
  elsif tool == 'oras' && ARGV[0] == 'resolve'
    reference = ARGV[1]
    version = if reference.include?('@')
      versions.find { |entry| entry['name'] == reference.split('@').last }
    else
      versions.find { |entry| entry.dig('metadata', 'container', 'tags').include?(reference.split(':').last) }
    end
    abort 'Unknown reference' unless version
    output = version.fetch('name')
  elsif tool == 'oras' && ARGV[0, 2] == ['manifest', 'fetch']
    version = versions.find { |entry| entry['name'] == ARGV[2].split('@').last }
    abort 'Unknown manifest' unless version
    output = JSON.generate(version.fetch('manifest'))
  elsif tool == 'oras' && ARGV[0, 2] == ['manifest', 'push']
    tag = ARGV[2].split(':').last
    versions.each { |entry| entry.dig('metadata', 'container', 'tags').delete(tag) }
    versions << {'id' => 100, 'name' => "sha256:#{'f' * 64}",
      'metadata' => {'container' => {'tags' => [tag]}}, 'manifest' => JSON.parse(File.read(ARGV[3]))}
    state['pushed'] << tag
  else
    abort "Unexpected #{tool} command: #{ARGV.inspect}"
  end
  File.write(file, JSON.generate(state))
  puts output unless output.empty?
  exit
end

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'

class CleanupCandidatesTest < Minitest::Test
  ACCEPTED = "sha256:#{'a' * 64}"
  OLD = "sha256:#{'b' * 64}"
  TAG = '27.0.1-xcode27'
  ALIAS = '27.0.1-xcode27-rc'
  PREFIX = 'miso-27.0.1-xcode-27-123-'
  CANDIDATE = "#{PREFIX}1"
  SCRIPT = File.expand_path('../cleanup-offline-candidates.sh', __dir__)

  def version(id, digest, tags, manifest = nil)
    {'id' => id, 'name' => digest, 'metadata' => {'container' => {'tags' => tags}},
      'manifest' => manifest || {'mediaType' => 'application/vnd.oci.image.manifest.v1+json',
        'schemaVersion' => 2, 'annotations' => {'fixture' => digest}}}
  end

  def run_cleanup(versions, superseded: true)
    Dir.mktmpdir('cleanup-regression-') do |directory|
      file = File.join(directory, 'state.json')
      File.write(file, JSON.generate(versions: versions, deleted: [], pushed: []))
      %w[gh oras].each { |name| File.symlink(File.expand_path(__FILE__), File.join(directory, name)) }
      environment = {'PATH' => "#{directory}:#{ENV.fetch('PATH')}", 'CLEANUP_TEST_STATE' => file,
        'GH_TOKEN' => 'fixture-token', 'GITHUB_ACTOR' => 'fixture-actor'}
      args = ['bash', SCRIPT, 'ghcr.io/example/images', TAG, ACCEPTED, PREFIX]
      args << OLD if superseded
      stdout, stderr, status = Open3.capture3(environment, *args)
      [JSON.parse(File.read(file)), status, stdout + stderr]
    end
  end

  def tags(state)
    state.fetch('versions').each_with_object({}) do |entry, result|
      entry.dig('metadata', 'container', 'tags').each { |tag| result[tag] = entry['name'] }
    end
  end

  def test_current_candidate_preserves_published_image
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG, CANDIDATE])], superseded: false)
    assert status.success?, log
    assert_equal({TAG => ACCEPTED}, tags(state))
    assert_equal [100], state['deleted']
  end

  def test_superseded_formal_alias_is_not_a_cleanup_error
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [ALIAS])])
    assert status.success?, log
    assert_equal({TAG => ACCEPTED, ALIAS => OLD}, tags(state))
    assert_empty state['deleted']
    assert_empty state['pushed']
  end

  def test_superseded_candidate_is_removed_without_deleting_its_alias
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [ALIAS, CANDIDATE])])
    assert status.success?, log
    assert_equal({TAG => ACCEPTED, ALIAS => OLD}, tags(state))
    assert_equal [100], state['deleted']
  end

  def test_superseded_candidate_without_an_alias_is_removed
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [CANDIDATE])])
    assert status.success?, log
    assert_equal({TAG => ACCEPTED}, tags(state))
    assert_equal [100], state['deleted']
  end

  def test_interrupted_isolation_resumes
    manifest = version(2, OLD, [])['manifest']
    manifest['annotations']['io.github.minimillionaire.cleanup-tag'] = CANDIDATE
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [ALIAS]),
      version(100, "sha256:#{'f' * 64}", [CANDIDATE], manifest)])
    assert status.success?, log
    assert_equal({TAG => ACCEPTED, ALIAS => OLD}, tags(state))
    assert_equal [100], state['deleted']
    assert_empty state['pushed']
  end

  def test_foreign_candidate_content_is_rejected
    state, status, = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [ALIAS]),
      version(3, "sha256:#{'c' * 64}", [CANDIDATE])])
    refute status.success?
    assert_empty state['deleted']
    assert_empty state['pushed']
    assert_equal OLD, tags(state)[ALIAS]
  end

  def test_wrong_published_digest_prevents_mutations
    state, status, = run_cleanup([version(1, ACCEPTED, []), version(2, OLD, [TAG, ALIAS, CANDIDATE])])
    refute status.success?
    assert_empty state['deleted']
    assert_empty state['pushed']
  end

  def test_other_build_candidates_are_preserved
    other = 'miso-27.0.1-xcode-27-456-1'
    state, status, log = run_cleanup([version(1, ACCEPTED, [TAG]), version(2, OLD, [ALIAS, CANDIDATE, other])])
    assert status.success?, log
    assert_equal({TAG => ACCEPTED, ALIAS => OLD, other => OLD}, tags(state))
    assert_equal [100], state['deleted']
  end
end
