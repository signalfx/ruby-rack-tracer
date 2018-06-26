require 'spec_helper'
require 'timeout'

RSpec.describe Rack::Tracer do
  let(:logger) { ArrayLogger.new }
  let(:tracer) { Test::Tracer.new(logger: logger) }
  let(:on_start_span) { spy }
  let(:on_finish_span) { spy }

  let(:ok_response) { [200, { 'Content-Type' => 'application/json' }, ['{"ok": true}']] }

  let(:env) do
    Rack::MockRequest.env_for('/test/this/route', method: method)
  end

  let(:method) { 'POST' }

  shared_examples 'calls on_start_span and on_finish_span callbacks' do
    it 'calls on_start_span callback' do
      respond_with { ok_response }
      span = tracer.spans.last
      expect(on_start_span).to have_received(:call).with(span)
    end

    it 'calls on_finish_span callback' do
      respond_with { ok_response }
      span = tracer.spans.last
      expect(on_finish_span).to have_received(:call).with(span)
    end
  end

  context 'when a new request' do
    it 'starts a new trace' do
      respond_with { ok_response }

      expect(tracer).to have_span(method).finished
    end

    it 'passes span to downstream' do
      respond_with do |env|
        span = tracer.spans.last
        expect(env['rack.span']).to eq(span)
        expect(env['rack.span']).to be_child_of(nil)
        ok_response
      end
    end

    include_examples 'calls on_start_span and on_finish_span callbacks'
  end

  context 'when already traced request' do
    let(:parent_span_name) { 'parent span' }
    let(:parent_span) { tracer.start_span(parent_span_name) }

    before { inject(parent_span.context, env) }

    it 'starts a child trace' do
      respond_with { ok_response }
      parent_span.finish

      expect(tracer).to have_span(parent_span_name).finished
      expect(tracer).to have_span(method).finished.child_of(parent_span_name)
    end

    it 'passes span to downstream' do
      respond_with do |env|
        span = tracer.spans.last
        expect(env['rack.span']).to eq(span)
        expect(env['rack.span']).to be_child_of(parent_span_name)
        ok_response
      end
    end

    include_examples 'calls on_start_span and on_finish_span callbacks'
  end

  context 'when already traced but untrusted request' do
    it 'starts a new trace' do
      respond_with(trust_incoming_span: false) { ok_response }
      expect(tracer).to have_span(method).finished.child_of(nil)
    end

    it 'does not pass incoming span to downstream' do
      respond_with(trust_incoming_span: false) do |env|
        span = tracer.spans.last
        expect(env['rack.span']).to eq(span)
        expect(env['rack.span']).to be_child_of(nil)
        ok_response
      end
    end

    include_examples 'calls on_start_span and on_finish_span callbacks'
  end

  context 'when an exception bubbles-up through the middlewares' do
    it 'finishes the span' do
      respond_with_timeout_error = lambda do
        respond_with { |_env| raise Timeout::Error }
      end

      expect(&respond_with_timeout_error).to raise_error do |_|
        expect(tracer).to have_span(method).finished
      end
    end

    it 'marks the span as failed' do
      respond_with_timeout_error = lambda do
        respond_with { |_env| raise Timeout::Error }
      end

      expect(&respond_with_timeout_error).to raise_error do |_|
        expect(tracer).to have_span(method).with_tags('error' => true)
      end
    end

    it 'logs the error' do
      exception = Timeout::Error.new
      respond_with_timeout_error = lambda do
        respond_with { |_env| raise exception }
      end

      expect(&respond_with_timeout_error).to raise_error do |thrown_exception|
        expect(tracer).to have_span(method).with_logs(
          event: 'error',
          :'error.kind' => thrown_exception.class.to_s,
          :'error.object' => thrown_exception,
          message: thrown_exception.message,
          stack: thrown_exception.backtrace.join("\n")
        )
      end
    end

    it 're-raise original exception' do
      expect { respond_with { |_env| raise Timeout::Error } }.to raise_error(Timeout::Error)
    end
  end

  def respond_with(trust_incoming_span: true, &app)
    middleware = described_class.new(
      app,
      tracer: tracer,
      on_start_span: on_start_span,
      on_finish_span: on_finish_span,
      trust_incoming_span: trust_incoming_span
    )
    middleware.call(env)
  end

  def inject(span_context, env)
    carrier = {}
    tracer.inject(span_context, OpenTracing::FORMAT_RACK, carrier)
    carrier.each do |k, v|
      env['HTTP_' + k.upcase.tr('-', '_')] = v
    end
  end
end
