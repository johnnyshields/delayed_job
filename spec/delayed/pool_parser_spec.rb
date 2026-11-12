require 'helper'

describe Delayed::PoolParser do
  subject { described_class.new }

  describe '#add and #pools' do
    it 'parsing pools' do
      %w[*:1 test_queue:4 mailers,misc:2].each do |str|
        subject.add(str)
      end

      expect(subject.pools).to eq [
        [[], 1],
        [['test_queue'], 4],
        [%w[mailers misc], 2]
      ]
    end

    it 'parses an optional thread count per pool' do
      subject.add('mailers,misc:2:5|*:1:3|tracking:4|reports::2')

      expect(subject.pools).to eq [
        [%w[mailers misc], 2, 5],
        [[], 1, 3],
        [['tracking'], 4],
        [['reports'], 0, 2]
      ]
    end

    it 'treats an invalid thread count as 1' do
      subject.add('mailers:2:0|misc:1:foo')
      expect(subject.pools).to eq [[['mailers'], 2, 1], [['misc'], 1, 1]]
    end

    it 'should allow pipe delimiter' do
      %w[*:1|test_queue:4 mailers,misc:2|foo,bar:3|baz:4].each do |str|
        subject.add(str)
      end

      expect(subject.pools).to eq [
        [[], 1],
        [['test_queue'], 4],
        [%w[mailers misc], 2],
        [%w[foo bar], 3],
        [['baz'], 4],
      ]
    end

    it 'should allow * to specify any pools' do
      subject.add('*:4')
      expect(subject.pools).to eq [[[], 4]]
    end

    it 'should allow blank to specify any pools' do
      subject.add(':4')
      expect(subject.pools).to eq [[[], 4]]
    end

    it 'should default to one worker if not specified' do
      subject.add('mailers')
      expect(subject.pools).to eq [[['mailers'], 1]]
    end

    it '#add should return self' do
      expect(subject.add('mailers:2|*:4')).to eq subject
    end
  end
end
