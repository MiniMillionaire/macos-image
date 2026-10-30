#!/usr/bin/env ruby
require 'json'

if %w[diskutil lsof].include?(File.basename($PROGRAM_NAME))
  path = ENV.fetch('SHRINK_TEST_STATE')
  state = JSON.parse(File.read(path))
  if File.basename($PROGRAM_NAME) == 'lsof'
    puts '123' if state['open']
    exit(state['open'] ? 0 : state.fetch('lsofExit', 1))
  end
  if ARGV.include?('--plist')
    exit 1 if state['limitsFail']
    puts %(<?xml version="1.0"?><plist version="1.0"><dict><key>min</key><integer>#{state.fetch('minimum')}</integer></dict></plist>)
  else
    state['resizes'] += 1
    File.write(path, JSON.generate(state))
    exit 1 if state['resizeFail']
    size = Integer(ARGV[ARGV.index('--size') + 1])
    File.truncate(ARGV.last, (size + 4095) / 4096 * 4096) unless state['wrongSize']
  end
  exit
end

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'

class ShrinkImageTest < Minitest::Test
  SCRIPT = File.expand_path('../shrink-image.sh', __dir__)

  def setup
    @root = Dir.mktmpdir('disk-shrink-')
    @disk = File.join(@root, 'disk.img')
    @receipt = File.join(@root, 'receipt.json')
    File.write(File.join(@root, 'config.json'), JSON.generate(os: 'darwin', diskFormat: 'raw'))
    File.open(@disk, 'w') { |file| file.truncate(160_000_000_000) }
    %w[diskutil lsof].each { |name| File.symlink(File.expand_path(__FILE__), File.join(@root, name)) }
    @state = {'minimum' => 40_000_000_000, 'resizes' => 0}
    @environment = {'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'SHRINK_TEST_STATE' => File.join(@root, 'state.json')}
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def shrink(check: false)
    File.write(@environment['SHRINK_TEST_STATE'], JSON.generate(@state))
    args = ['bash', SCRIPT]
    args << '--check' if check
    log, status = Open3.capture2e(@environment, *args, @root, @receipt)
    @state = JSON.parse(File.read(@environment['SHRINK_TEST_STATE']))
    [status.success?, log]
  end

  def test_reserve_rounding_and_sector_alignment
    @state['minimum'] = 41_410_065_409
    success, log = shrink
    assert success, log
    receipt = JSON.parse(File.read(@receipt))
    assert_equal 60_000_000_000, receipt['targetBytes']
    assert_equal 60_000_002_048, File.size(@disk)
    assert_operator receipt['targetBytes'] - @state['minimum'], :>=, 8 * 1024**3
    success, log = shrink(check: true)
    assert success, log
    assert_equal 1, @state['resizes']
  end

  def test_exact_rounding_boundary_does_not_waste_another_ten_gigabytes
    @state['minimum'] = 41_410_065_408
    success, log = shrink
    assert success, log
    assert_equal 50_000_003_072, File.size(@disk)
  end

  def test_open_disk_or_failed_inspection_prevents_mutation
    [{'open' => true}, {'lsofExit' => 2}, {'limitsFail' => true}, {'minimum' => 155_000_000_000}].each do |fault|
      @state = {'minimum' => 40_000_000_000, 'resizes' => 0}.merge(fault)
      success, = shrink
      refute success
      assert_equal 0, @state['resizes']
      assert_equal 160_000_000_000, File.size(@disk)
      refute File.exist?(@receipt)
    end
  end

  def test_failed_or_ineffective_resize_never_writes_a_success_receipt
    %w[resizeFail wrongSize].each do |fault|
      @state = {'minimum' => 40_000_000_000, 'resizes' => 0, fault => true}
      success, = shrink
      refute success
      refute File.exist?(@receipt)
    end
  end

  def test_missing_receipt_and_later_disk_changes_are_rejected
    success, = shrink(check: true)
    refute success
    success, log = shrink
    assert success, log
    File.open(@disk, 'r+') { |file| file.write('changed after acceptance') }
    success, = shrink(check: true)
    refute success
  end
end
