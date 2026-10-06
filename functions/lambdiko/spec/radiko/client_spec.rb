require 'spec_helper'
require 'date'
require 'net/http'
require 'radiko/client'

RSpec.describe 'Radiko::Client' do
  let(:client) { Radiko::Client.new }

  let(:program_xml) { <<~XML }
      <radiko>
        <stations>
          <station id="TBS">
            <name>TBSラジオ</name>
            <progs>
              <date>20240407</date>
              <prog ft="20240407220000" to="20240407230000">
                <title>テスト番組</title>
              </prog>
            </progs>
          </station>
          <station id="QRR">
            <name>文化放送</name>
            <progs><date>20240407</date></progs>
          </station>
        </stations>
      </radiko>
    XML

  # Net::HTTP.get_response の戻り値を模したレスポンス
  def http_response(klass, code, body)
    response = klass.new('1.1', code, 'message')
    allow(response).to receive(:body).and_return(body)
    response
  end

  describe '#get_program_xml' do
    let(:date) { Date.new(2024, 4, 7) }

    it '日付・放送局IDを指定した番組表URLから XML を取得してパースする' do
      allow(Net::HTTP).to receive(:get_response).and_return(
        http_response(Net::HTTPOK, '200', program_xml)
      )

      xml_doc = client.get_program_xml(date, 'TBS')

      expect(Net::HTTP).to have_received(:get_response).with(
        URI.parse('https://radiko.jp/v3/program/station/date/20240407/TBS.xml')
      )
      expect(xml_doc).to be_a(REXML::Document)
      expect(xml_doc.elements['//progs/prog/title'].text).to eq('テスト番組')
    end

    it 'HTTP ステータスが成功以外のとき例外を発生させる' do
      allow(Net::HTTP).to receive(:get_response).and_return(
        http_response(Net::HTTPInternalServerError, '500', '')
      )

      expect { client.get_program_xml(date, 'TBS') }.to raise_error(
        RuntimeError,
        'Failed to fetch XML: HTTP 500 - https://radiko.jp/v3/program/station/date/20240407/TBS.xml'
      )
    end
  end

  describe '#parse_station_name' do
    let(:xml_doc) { REXML::Document.new(program_xml) }

    it 'station_id を省略すると最初の放送局名を返す' do
      expect(client.parse_station_name(xml_doc)).to eq('TBSラジオ')
    end

    it 'station_id を指定すると該当する放送局名を返す' do
      expect(client.parse_station_name(xml_doc, 'QRR')).to eq('文化放送')
    end

    it '該当する放送局がなければ nil を返す' do
      expect(client.parse_station_name(xml_doc, 'XXX')).to be_nil
    end

    it '放送局が存在しなければ nil を返す' do
      empty_doc = REXML::Document.new('<radiko><stations/></radiko>')

      expect(client.parse_station_name(empty_doc)).to be_nil
    end
  end
end
