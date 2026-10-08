require 'spec_helper'
require 'json'
require 'time'
require 'lambdiko/notify'

RSpec.describe 'Lambdiko::Notify' do
  let(:topic_arn) { 'arn:aws:sns:ap-northeast-1:123456789012:test-topic' }
  let(:sns_client) { instance_double(Aws::SNS::Client) }
  let(:published) { [] }

  # SNS に渡された message（JSON）をパースして返す
  let(:message) { JSON.parse(published.last[:message]) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SNS_TOPIC_ARN').and_return(topic_arn)
    allow(Aws::SNS::Client).to receive(:new).and_return(sns_client)
    allow(sns_client).to receive(:publish) { |**args| published << args }
  end

  describe '#sns_publish' do
    it 'SNS_TOPIC_ARN 宛に message を JSON 文字列として publish する' do
      sns_publish({ title: 'タイトル', status: 'OK' })

      expect(published.size).to eq(1)
      expect(published.last[:topic_arn]).to eq(topic_arn)
      expect(JSON.parse(published.last[:message])).to eq('title' => 'タイトル', 'status' => 'OK')
    end
  end

  describe '#send_download_notify' do
    context 'status が :ok のとき' do
      let(:fields) { [{ name: 'Title', value: '安部礼司', inline: false }] }

      before do
        send_download_notify(status: :ok, description: 's3://bucket/file.m4a', fields: fields)
      end

      it 'タイトルを「ダウンロード完了」、ステータスを OK にする' do
        expect(message).to include(
          'service' => 'Lambdiko',
          'title' => 'ダウンロード完了',
          'status' => 'OK',
          'description' => 's3://bucket/file.m4a'
        )
      end

      it 'fields をそのまま通知に含める' do
        expect(message['fields']).to eq(
          [{ 'name' => 'Title', 'value' => '安部礼司', 'inline' => false }]
        )
      end

      it 'timestamp を含める' do
        expect { Time.parse(message['timestamp']) }.not_to raise_error
      end
    end

    context 'status が :error のとき' do
      before { send_download_notify(status: :error, description: 'RuntimeError') }

      it 'タイトルを「ダウンロードエラー」、ステータスを ERROR にする' do
        expect(message).to include(
          'title' => 'ダウンロードエラー',
          'status' => 'ERROR',
          'description' => 'RuntimeError'
        )
      end

      it 'fields を省略すると nil になる' do
        expect(message['fields']).to be_nil
      end
    end
  end

  describe '#send_search_notify' do
    {
      info: %w[リクエスト成功 INFO],
      warn: %w[検索結果なし WARN],
      error: %w[リクエストエラー ERROR]
    }.each do |status, (title, status_text)|
      context "status が :#{status} のとき" do
        before { send_search_notify(status: status, description: 'detail') }

        it "タイトルを「#{title}」、ステータスを #{status_text} にする" do
          expect(message).to include(
            'service' => 'Lambdiko',
            'title' => title,
            'status' => status_text,
            'description' => 'detail'
          )
        end
      end
    end

    context 'status を省略したとき（検索テスト）' do
      before { send_search_notify(description: 'test result') }

      it 'タイトルを「検索テスト」、ステータスを空文字にする' do
        expect(message).to include(
          'title' => '検索テスト',
          'status' => '',
          'description' => 'test result'
        )
      end

      it 'fields を含めない' do
        expect(message).not_to have_key('fields')
      end
    end

    it 'timestamp を含める' do
      send_search_notify(status: :info, description: 'detail')

      expect { Time.parse(message['timestamp']) }.not_to raise_error
    end
  end
end
