require_relative '../../helper'
require_relative 'shared_examples'

describe Delayed::Launcher::Forking do
  let(:options) { {} }
  subject { described_class.new(options) }

  before do
    @workers = []
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(nil))
    allow_any_instance_of(described_class).to receive(:run_loop).and_return(nil)
    allow_any_instance_of(described_class).to receive(:fork_worker) { |_, *args| @workers << args }
    allow_any_instance_of(described_class).to receive(:setup_single_worker) do
      @workers << [subject.send(:get_name, subject.send(:process_identifier)), subject.instance_variable_get(:'@options')]
    end
  end

  def verify_worker_processes
    subject.launch
    expect(@workers).to eq(exp)
  end

  it_behaves_like 'launcher shared examples'

  describe '#launch' do
    before do
      allow(Delayed::Worker).to receive(:before_fork)
      allow_any_instance_of(described_class).to receive(:prepare_for_fork)
    end

    shared_examples 'a forking parent' do
      it 'prepares for forking, then supervises the forked workers' do
        expect(subject).to receive(:prepare_for_fork).ordered
        expect(Delayed::Worker).to receive(:before_fork).ordered
        expect(subject).to receive(:fork_worker).at_least(:once).ordered
        expect(subject).to receive(:run_loop).ordered
        subject.launch
      end
    end

    shared_examples 'a single worker process' do
      it 'runs the worker in this process without forking' do
        expect(subject).not_to receive(:prepare_for_fork)
        expect(Delayed::Worker).not_to receive(:before_fork)
        expect(subject).not_to receive(:fork_worker)
        expect(subject).not_to receive(:run_loop)
        subject.launch
      end
    end

    context 'with multiple workers' do
      let(:options) { {:worker_count => 2} }
      it_behaves_like 'a forking parent'
    end

    # Regression: pools with the default worker count (1) used to fork
    # without Worker.before_fork (crashing the children in after_fork) and
    # without supervising them (the parent exited immediately).
    context 'with pools and the default worker count' do
      let(:options) { {:pools => [[['mailers'], 2]]} }
      it_behaves_like 'a forking parent'
    end

    context 'with a single pool of one worker' do
      let(:options) { {:pools => [[[], 1]]} }
      it_behaves_like 'a forking parent'
    end

    context 'with a single worker' do
      let(:options) { {} }
      it_behaves_like 'a single worker process'
    end

    context 'with an identifier and multiple workers' do
      let(:options) { {:identifier => 'abc', :worker_count => 2} }
      it_behaves_like 'a single worker process'
    end
  end

  describe '#prepare_for_fork' do
    let(:config) { double('config', :cache_classes => true) }
    let(:application) { double('application', :config => config) }

    before { allow(subject).to receive(:warmup_heap) }

    it 'eager loads the Rails application' do
      stub_const('Rails', double('Rails', :application => application))
      expect(application).to receive(:eager_load!)
      subject.send(:prepare_for_fork)
    end

    it 'does not eager load when code reloading is enabled' do
      allow(config).to receive(:cache_classes).and_return(false)
      stub_const('Rails', double('Rails', :application => application))
      expect(application).not_to receive(:eager_load!)
      subject.send(:prepare_for_fork)
    end

    it 'skips eager loading without a Rails application' do
      stub_const('Rails', double('Rails', :application => nil))
      expect { subject.send(:prepare_for_fork) }.not_to raise_error
    end

    it 'warms up the heap' do
      stub_const('Rails', double('Rails', :application => nil))
      expect(subject).to receive(:warmup_heap)
      subject.send(:prepare_for_fork)
    end
  end

  describe '#warmup_heap' do
    it 'uses Process.warmup when available' do
      skip 'Process.warmup requires Ruby 3.3' unless Process.respond_to?(:warmup)
      expect(Process).to receive(:warmup)
      expect(GC).not_to receive(:start)
      subject.send(:warmup_heap)
    end

    it 'falls back to a full GC and compaction' do
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:warmup).and_return(false)
      expect(GC).to receive(:start)
      expect(GC).to receive(:compact) if GC.respond_to?(:compact)
      subject.send(:warmup_heap)
    end

    it 'tolerates platforms without compaction' do
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:warmup).and_return(false)
      allow(GC).to receive(:start)
      allow(GC).to receive(:respond_to?).and_call_original
      allow(GC).to receive(:respond_to?).with(:compact).and_return(true)
      allow(GC).to receive(:compact).and_raise(NotImplementedError)
      expect { subject.send(:warmup_heap) }.not_to raise_error
    end
  end
end
