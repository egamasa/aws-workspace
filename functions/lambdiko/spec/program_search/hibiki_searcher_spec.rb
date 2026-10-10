require 'spec_helper'
require_relative '../../program-search/lib/hibiki_searcher'

RSpec.describe HibikiSearcher do
  let(:api_base) { HibikiSearcher::API_BASE_URL }
  let(:headers) { HibikiSearcher::API_HEADERS }

  def build_searcher(week)
    described_class.new({ 'week' => week, 'target' => 'name', 'keyword' => 'テスト' })
  end

  describe '#search' do
    {
      'mon' => 1,
      'tue' => 2,
      'wed' => 3,
      'thu' => 4,
      'fri' => 5,
      'sat' => 6,
      'sun' => 6
    }.each do |week, day_of_week|
      it "week が #{week} のとき day_of_week=#{day_of_week} で番組表を取得する" do
        searcher = build_searcher(week)
        allow(searcher).to receive(:http_get_json).and_return([])

        searcher.search

        expect(searcher).to have_received(:http_get_json).with(
          "#{api_base}/programs?day_of_week=#{day_of_week}",
          headers
        )
      end
    end

    it 'week が文字列でなくシンボルでも変換できる' do
      searcher = build_searcher(:sat)
      allow(searcher).to receive(:http_get_json).and_return([])

      searcher.search

      expect(searcher).to have_received(:http_get_json).with(
        "#{api_base}/programs?day_of_week=6",
        headers
      )
    end

    it '未対応の week を指定すると原因が分かる ArgumentError を発生させ API を呼ばない' do
      searcher = build_searcher('xxx')
      allow(searcher).to receive(:http_get_json)

      expect { searcher.search }.to raise_error(
        ArgumentError,
        'Unsupported week for HiBiKi: xxx'
      )
      expect(searcher).not_to have_received(:http_get_json)
    end

    it 'week が nil のとき ArgumentError を発生させる' do
      searcher = build_searcher(nil)

      expect { searcher.search }.to raise_error(ArgumentError, /Unsupported week for HiBiKi/)
    end

    it 'キーワードに一致する番組のみ番組情報を取得して返す' do
      searcher = build_searcher('sat')
      program_list = [
        { 'access_id' => 'a', 'name' => 'テスト番組' },
        { 'access_id' => 'b', 'name' => '別の番組' }
      ]
      program_info = {
        'name' => 'テスト番組',
        'cast' => '出演者',
        'sp_image_url' => 'https://example.com/a.jpg',
        'episode_updated_at' => '2024/04/06 12:00:00',
        'episode' => {
          'name' => '第1回',
          'video' => {
            'id' => 123
          },
          'episode_parts' => [{ 'description' => '説明' }]
        }
      }
      allow(searcher).to receive(:http_get_json).with(
        "#{api_base}/programs?day_of_week=6",
        headers
      ).and_return(program_list)
      allow(searcher).to receive(:http_get_json).with(
        "#{api_base}/programs/a",
        headers
      ).and_return(program_info)

      results = searcher.search

      expect(results.size).to eq(1)
      expect(results.first).to include(title: 'テスト番組', station_id: 'HiBiKi', to: 123)
    end
  end
end
