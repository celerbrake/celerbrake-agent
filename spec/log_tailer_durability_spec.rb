require 'spec_helper'
require 'tmpdir'
require 'stringio'

# The persistent cursor and rotation handling (review finding R04): a restart
# or a rotation must never skip a complete line.
RSpec.describe Celerbrake::Agent::LogTailer, 'durability' do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      @log = File.join(dir, 'production.log')
      @state = File.join(dir, 'state')
      ex.run
    ensure
      @tailers&.each(&:close)
    end
  end

  # A fresh agent process: a new cursor store read from disk, a new tailer.
  def start_agent
    store = Celerbrake::Agent::CursorStore.new(dir: @state, logger: logger)
    tailer = described_class.new(path: @log, logger: logger, cursor_store: store)
    (@tailers ||= []) << tailer
    tailer
  end

  def write(path, *lines)
    File.open(path, 'a') { |io| lines.each { |l| io.puts(%({"message":"#{l}"})) } }
  end

  def messages(events)
    events.map { |e| e[:message] }
  end

  # read + commit, the way the runner does once the batch is durable
  def read_and_commit(tailer)
    events = tailer.read_new
    tailer.commit!
    events
  end

  it 'tails from the end on the first run, and persists that choice so a restart does not skip lines' do
    write(@log, 'history')
    agent = start_agent
    expect(read_and_commit(agent)).to eq([]) # first installation: tail from end
    expect(log_io.string).to include('no saved cursor', 'first run')

    write(@log, 'while-down-1', 'while-down-2') # the agent is restarted before reading these
    restarted = start_agent
    expect(messages(read_and_commit(restarted))).to eq(%w[while-down-1 while-down-2])

    cursor = JSON.parse(File.read(File.join(@state, 'cursor.json')))['files'][File.expand_path(@log)]
    expect(cursor.keys).to include('dev', 'ino', 'pos', 'size', 'updated_at')
    expect(cursor['pos']).to eq(File.size(@log))
  end

  it 'replays lines read but never committed after a restart, with the same event ids' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'a', 'b')

    lost = agent.read_new # read, then the process dies before spooling
    restarted = start_agent
    again = read_and_commit(restarted)

    expect(messages(again)).to eq(%w[a b])
    expect(again.map { |e| e[:event_id] }).to eq(lost.map { |e| e[:event_id] }) # dedup-able downstream
    expect(again.map { |e| e[:event_id] }.uniq.size).to eq(2)
  end

  it 'rewind! returns the same lines on the next read' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'x')

    expect(messages(agent.read_new)).to eq(['x'])
    agent.rewind!
    expect(messages(agent.read_new)).to eq(['x'])
    agent.commit!
    expect(agent.read_new).to eq([])
  end

  it 'finishes the old file and reads a SMALLER replacement from the start after a rename rotation' do
    write(@log, 'old-1', 'old-2', 'old-3')
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'old-tail') # written just before rotation, not read yet

    File.rename(@log, "#{@log}.1")
    write(@log, 'n') # shorter than the old offset

    expect(messages(read_and_commit(agent))).to eq(%w[old-tail n])
    write(@log, 'n2')
    expect(messages(read_and_commit(agent))).to eq(['n2'])
  end

  it 'reads a LARGER replacement from byte 0 (the head is not lost)' do
    write(@log, 'short')
    agent = start_agent
    read_and_commit(agent)

    File.rename(@log, "#{@log}.1")
    write(@log, 'new-first-line-is-long', 'new-second', 'new-third') # larger than the old offset

    expect(messages(read_and_commit(agent))).to eq(%w[new-first-line-is-long new-second new-third])
  end

  it 'keeps reading the old file while the path is missing, then switches when it reappears' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'before-rename')
    File.rename(@log, "#{@log}.1")
    write("#{@log}.1", 'late-write-to-old-fd')

    expect(messages(read_and_commit(agent))).to eq(%w[before-rename late-write-to-old-fd])
    write(@log, 'fresh')
    expect(messages(read_and_commit(agent))).to eq(['fresh'])
    expect(log_io.string).to include('was rotated')
  end

  it 'finishes the rotated file found by inode when the rotation happened while the agent was down' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'unread-before-rotation')
    agent.close # agent goes down

    File.rename(@log, "#{@log}.1")
    write(@log, 'after-rotation')

    restarted = start_agent
    expect(messages(read_and_commit(restarted))).to eq(%w[unread-before-rotation after-rotation])
  end

  it 'reads the new file from the start when the rotated file is gone' do
    write(@log, 'a')
    agent = start_agent
    read_and_commit(agent)
    agent.close
    File.delete(@log)
    write(@log, 'b', 'c')

    restarted = start_agent
    expect(messages(read_and_commit(restarted))).to eq(%w[b c])
    expect(log_io.string).to include('replaced while the agent was down')
  end

  it 'restarts at 0 after an in-place truncation (copytruncate) to a smaller size' do
    write(@log, 'one', 'two', 'three')
    agent = start_agent
    read_and_commit(agent)

    File.truncate(@log, 0)
    write(@log, 'x')
    expect(messages(read_and_commit(agent))).to eq(['x'])
  end

  it 'detects a truncation that was rewritten past the old offset before the next read' do
    write(@log, 'one', 'two')
    agent = start_agent
    read_and_commit(agent)

    File.truncate(@log, 0)
    write(@log, 'rewritten-line-1', 'rewritten-line-2', 'rewritten-line-3') # now longer than before

    expect(messages(read_and_commit(agent))).to eq(%w[rewritten-line-1 rewritten-line-2 rewritten-line-3])
  end

  it 'restarts at 0 when the file was truncated while the agent was down' do
    write(@log, 'one', 'two', 'three')
    agent = start_agent
    read_and_commit(agent)
    agent.close
    File.truncate(@log, 0)
    write(@log, 'z')

    expect(messages(read_and_commit(start_agent))).to eq(['z'])
  end

  it 'keeps a partial line across a restart and ships it once it completes' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    File.open(@log, 'a') { |io| io.write('{"message":"split') }
    expect(read_and_commit(agent)).to eq([])
    agent.close

    File.open(@log, 'a') { |io| io.write(%(-line"}\n)) }
    restarted = start_agent
    expect(messages(read_and_commit(restarted))).to eq(['split-line'])
  end

  it 'ships a file that did not exist at start from its first line' do
    agent = start_agent
    expect(read_and_commit(agent)).to eq([])
    write(@log, 'boot-line')
    expect(messages(read_and_commit(agent))).to eq(['boot-line'])
  end

  it 'treats an unreadable cursor file as a first run' do
    FileUtils.mkdir_p(@state)
    File.write(File.join(@state, 'cursor.json'), '{"files": {')
    write(@log, 'history')
    agent = start_agent
    expect(read_and_commit(agent)).to eq([])
    expect(log_io.string).to include('cursor file', 'unreadable')
    write(@log, 'new')
    expect(messages(read_and_commit(agent))).to eq(['new'])
  end

  it 'reports the bytes not read yet' do
    write(@log)
    agent = start_agent
    read_and_commit(agent)
    write(@log, 'pending')
    expect(agent.lag_bytes).to eq(%({"message":"pending"}\n).bytesize)
    read_and_commit(agent)
    expect(agent.lag_bytes).to eq(0)
  end
end
