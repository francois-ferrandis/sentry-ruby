require "spec_helper"
require 'contexts/with_request_mock'

RSpec.describe Sentry::Net::HTTP do
  include_context "with request mock"

  let(:string_io) { StringIO.new }
  let(:logger) do
    ::Logger.new(string_io)
  end

  context "with tracing enabled" do
    before do
      perform_basic_setup do |config|
        config.traces_sample_rate = 1.0
        config.transport.transport_class = Sentry::HTTPTransport
        config.logger = logger
        # the dsn needs to have a real host so we can make a real connection before sending a failed request
        config.dsn = 'http://foobarbaz@o447951.ingest.sentry.io/5434472'
      end
    end

    context "with config.send_default_pii = true" do
      before do
        Sentry.configuration.send_default_pii = true
      end

      it "records the request's span with query string" do
        stub_normal_response

        transaction = Sentry.start_transaction
        Sentry.get_current_scope.set_span(transaction)

        response = Net::HTTP.get_response(URI("http://example.com/path?foo=bar"))

        expect(response.code).to eq("200")
        expect(transaction.span_recorder.spans.count).to eq(2)

        request_span = transaction.span_recorder.spans.last
        expect(request_span.op).to eq("http.client")
        expect(request_span.start_timestamp).not_to be_nil
        expect(request_span.timestamp).not_to be_nil
        expect(request_span.start_timestamp).not_to eq(request_span.timestamp)
        expect(request_span.description).to eq("GET http://example.com/path?foo=bar")
        expect(request_span.data).to eq({ status: 200 })
      end
    end

    context "with config.send_default_pii = true" do
      before do
        Sentry.configuration.send_default_pii = false
      end

      it "records the request's span with query string" do
        stub_normal_response

        transaction = Sentry.start_transaction
        Sentry.get_current_scope.set_span(transaction)

        response = Net::HTTP.get_response(URI("http://example.com/path?foo=bar"))

        expect(response.code).to eq("200")
        expect(transaction.span_recorder.spans.count).to eq(2)

        request_span = transaction.span_recorder.spans.last
        expect(request_span.op).to eq("http.client")
        expect(request_span.start_timestamp).not_to be_nil
        expect(request_span.timestamp).not_to be_nil
        expect(request_span.start_timestamp).not_to eq(request_span.timestamp)
        expect(request_span.description).to eq("GET http://example.com/path")
        expect(request_span.data).to eq({ status: 200 })
      end
    end

    it "adds sentry-trace header to the request header" do
      stub_normal_response

      uri = URI("http://example.com/path")
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri.request_uri)

      transaction = Sentry.start_transaction
      Sentry.get_current_scope.set_span(transaction)

      response = http.request(request)

      expect(response.code).to eq("200")
      expect(string_io.string).to match(
        /\[Tracing\] Adding sentry-trace header to outgoing request:/
      )
      request_span = transaction.span_recorder.spans.last
      expect(request["sentry-trace"]).to eq(request_span.to_sentry_trace)
    end

    context "with config.propagate_trace = false" do
      before do
        Sentry.configuration.propagate_traces = false
      end

      it "doesn't add the sentry-trace header to outgoing requests" do
        stub_normal_response

        uri = URI("http://example.com/path")
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Get.new(uri.request_uri)

        transaction = Sentry.start_transaction
        Sentry.get_current_scope.set_span(transaction)

        response = http.request(request)

        expect(response.code).to eq("200")
        expect(string_io.string).not_to match(
          /Adding sentry-trace header to outgoing request:/
        )
        expect(request.key?("sentry-trace")).to eq(false)
      end
    end

    it "doesn't record span for the SDK's request" do
      stub_sentry_response

      transaction = Sentry.start_transaction
      Sentry.get_current_scope.set_span(transaction)

      Sentry.capture_message("foo")

      # make sure the request was actually made
      expect(string_io.string).to match(/bad sentry DSN public key/)
      expect(transaction.span_recorder.spans.count).to eq(1)
    end

    context "when there're multiple requests" do
      let(:transaction) { Sentry.start_transaction }

      before do
        Sentry.get_current_scope.set_span(transaction)
      end

      def verify_spans(transaction)
        expect(transaction.span_recorder.spans.count).to eq(3)
        expect(transaction.span_recorder.spans[0]).to eq(transaction)

        request_span = transaction.span_recorder.spans[1]
        expect(request_span.op).to eq("http.client")
        expect(request_span.start_timestamp).not_to be_nil
        expect(request_span.timestamp).not_to be_nil
        expect(request_span.start_timestamp).not_to eq(request_span.timestamp)
        expect(request_span.description).to eq("GET http://example.com/path")
        expect(request_span.data).to eq({ status: 200 })

        request_span = transaction.span_recorder.spans[2]
        expect(request_span.op).to eq("http.client")
        expect(request_span.start_timestamp).not_to be_nil
        expect(request_span.timestamp).not_to be_nil
        expect(request_span.start_timestamp).not_to eq(request_span.timestamp)
        expect(request_span.description).to eq("GET http://example.com/path")
        expect(request_span.data).to eq({ status: 404 })
      end

      it "doesn't mess different requests' data together" do
        stub_normal_response(code: "200")
        response = Net::HTTP.get_response(URI("http://example.com/path?foo=bar"))
        expect(response.code).to eq("200")

        stub_normal_response(code: "404")
        response = Net::HTTP.get_response(URI("http://example.com/path?foo=bar"))
        expect(response.code).to eq("404")

        verify_spans(transaction)
      end

      it "doesn't mess different requests' data together when making multiple requests with Net::HTTP.start" do
        Net::HTTP.start("example.com") do |http|
          stub_normal_response(code: "200")
          request = Net::HTTP::Get.new("/path?foo=bar")
          response = http.request(request)
          expect(response.code).to eq("200")

          stub_normal_response(code: "404")
          request = Net::HTTP::Get.new("/path?foo=bar")
          response = http.request(request)
          expect(response.code).to eq("404")
        end

        verify_spans(transaction)
      end

      context "with nested span" do
        let(:span) { transaction.start_child(op: "child span") }

        before do
          Sentry.get_current_scope.set_span(span)
        end

        it "attaches http spans to the span instead of top-level transaction" do
          stub_normal_response(code: "200")
          response = Net::HTTP.get_response(URI("http://example.com/path?foo=bar"))
          expect(response.code).to eq("200")

          expect(transaction.span_recorder.spans.count).to eq(3)
          expect(span.parent_span_id).to eq(transaction.span_id)
          http_span = transaction.span_recorder.spans.last
          expect(http_span.parent_span_id).to eq(span.span_id)
        end
      end
    end

    context "with unsampled transaction" do
      it "doesn't do anything" do
        stub_normal_response

        transaction = Sentry.start_transaction(sampled: false)
        expect(transaction).not_to receive(:start_child)
        Sentry.get_current_scope.set_span(transaction)

        response = Net::HTTP.get_response(URI("http://example.com/path"))

        expect(response.code).to eq("200")
        expect(transaction.span_recorder.spans.count).to eq(1)
      end
    end
  end

  context "without tracing enabled nor http_logger" do
    before do
      perform_basic_setup
    end

    it "doesn't affect the HTTP lib anything" do
      stub_normal_response

      response = Net::HTTP.get_response(URI("http://example.com/path"))
      expect(response.code).to eq("200")

      expect(Sentry.get_current_scope.get_transaction).to eq(nil)
      expect(Sentry.get_current_scope.breadcrumbs.peek).to eq(nil)
    end
  end

  context "without SDK" do
    it "doesn't affect the HTTP lib anything" do
      stub_normal_response

      response = Net::HTTP.get_response(URI("http://example.com/path"))
      expect(response.code).to eq("200")
    end
  end
end
