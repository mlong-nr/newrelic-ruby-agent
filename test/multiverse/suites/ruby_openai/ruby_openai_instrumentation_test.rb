# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative 'openai_helpers'

class RubyOpenAIInstrumentationTest < Minitest::Test
  include OpenAIHelpers
  # some of the private methods are too difficult to stub
  # we can test them directly by including the module
  include NewRelic::Agent::Instrumentation::OpenAI

  def setup
    @aggregator = NewRelic::Agent.agent.custom_event_aggregator
  end

  def teardown
    NewRelic::Agent.drop_buffered_data
  end

  def test_instrumentation_doesnt_record_anything_with_other_paths_that_use_json_post
    in_transaction do
      stub_post_request do
        connection_client.json_post(path: '/edits', parameters: edits_params)
      end
    end

    refute_metrics_recorded(["Supportability/Ruby/ML/OpenAI/#{::OpenAI::VERSION}"])
  end

  def test_openai_metric_recorded_for_chat_completions_every_time
    in_transaction do
      stub_post_request do
        client.chat(parameters: chat_params)
        client.chat(parameters: chat_params)
      end
    end

    assert_metrics_recorded({"Supportability/Ruby/ML/OpenAI/#{::OpenAI::VERSION}" => {call_count: 2}})
  end

  def test_openai_chat_completion_segment_name
    txn = in_transaction do
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end

    refute_nil chat_completion_segment(txn)
  end

  def test_summary_event_has_duration_of_segment
    txn = in_transaction do
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end

    segment = chat_completion_segment(txn)

    assert_equal segment.duration, segment.llm_event.duration
  end

  def test_chat_completion_records_summary_event
    in_transaction do
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end
    _, events = @aggregator.harvest!
    summary_events = events.filter { |event| event[0]['type'] == NewRelic::Agent::Llm::ChatCompletionSummary::EVENT_NAME }

    assert_equal 1, summary_events.length

    # TODO: Write tests that validate the event has the correct attributes
  end

  def test_chat_completion_records_message_events
    in_transaction do
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end
    _, events = @aggregator.harvest!
    message_events = events.filter { |event| event[0]['type'] == NewRelic::Agent::Llm::ChatCompletionMessage::EVENT_NAME }

    assert_equal 5, message_events.length
    # TODO: Write tests that validate the event has the correct attributes
  end

  def test_segment_error_captured_if_raised
    txn = raise_segment_error do
      client.chat(parameters: chat_params)
    end

    assert_segment_noticed_error(txn, /Llm.*OpenAI\/.*/, RuntimeError.name, /deception/i)
  end

  def test_segment_summary_event_sets_error_true_if_raised
    txn = raise_segment_error do
      client.chat(parameters: chat_params)
    end

    segment = chat_completion_segment(txn)

    refute_nil segment.llm_event
    assert_truthy segment.llm_event.error
  end

  def test_chat_completion_returns_chat_completion_body
    result = nil

    in_transaction do
      stub_post_request do
        result = client.chat(parameters: chat_params)
      end
    end

    if Gem::Version.new(::OpenAI::VERSION) >= Gem::Version.new('6.0.0')
      assert_equal ChatResponse.new.body, result
    else
      assert_equal ChatResponse.new.body(return_value: true), result
    end
  end

  def test_set_llm_agent_attribute_on_chat_transaction
    in_transaction do |txn|
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end

    assert_truthy harvest_transaction_events![1][0][2][:llm]
  end

  def test_llm_custom_attributes_added_to_summary_events
    in_transaction do
      NewRelic::Agent.add_custom_attributes({
        'llm.conversation_id' => '1993',
        'llm.JurassicPark' => 'Steven Spielberg',
        'trex' => 'carnivore'
      })
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end

    _, events = @aggregator.harvest!
    summary_event = events.find { |event| event[0]['type'] == NewRelic::Agent::Llm::ChatCompletionSummary::EVENT_NAME }

    assert_equal '1993', summary_event[1]['conversation_id']
    assert_equal 'Steven Spielberg', summary_event[1]['JurassicPark']
    refute summary_event[1]['trex']
  end

  def test_llm_custom_attributes_added_to_embedding_events
    in_transaction do
      NewRelic::Agent.add_custom_attributes({
        'llm.conversation_id' => '1997',
        'llm.TheLostWorld' => 'Steven Spielberg',
        'triceratops' => 'herbivore'
      })
      stub_post_request do
        client.embeddings(parameters: chat_params)
      end
    end
    _, events = @aggregator.harvest!
    embedding_event = events.find { |event| event[0]['type'] == NewRelic::Agent::Llm::Embedding::EVENT_NAME }

    assert_equal '1997', embedding_event[1]['conversation_id']
    assert_equal 'Steven Spielberg', embedding_event[1]['TheLostWorld']
    refute embedding_event[1]['fruit']
  end

  def test_llm_custom_attributes_added_to_message_events
    in_transaction do
      NewRelic::Agent.add_custom_attributes({
        'llm.conversation_id' => '2001',
        'llm.JurassicParkIII' => 'Joe Johnston',
        'Pterosaur' => 'Can fly — scary!'
      })
      stub_post_request do
        client.chat(parameters: chat_params)
      end
    end
    _, events = @aggregator.harvest!
    message_events = events.filter { |event| event[0]['type'] == NewRelic::Agent::Llm::ChatCompletionMessage::EVENT_NAME }

    message_events.each do |event|
      assert_equal '2001', event[1]['conversation_id']
      assert_equal 'Joe Johnston', event[1]['JurassicParkIII']
      refute event[1]['Pterosaur']
    end
  end

  def test_openai_embedding_segment_name
    txn = in_transaction do
      stub_embeddings_post_request do
        client.embeddings(parameters: embeddings_params)
      end
    end

    refute_nil embedding_segment(txn)
  end

  def test_embedding_has_duration_of_segment
    txn = in_transaction do
      stub_embeddings_post_request do
        client.embeddings(parameters: embeddings_params)
      end
    end

    segment = embedding_segment(txn)

    assert_equal segment.duration, segment.llm_event.duration
  end

  def test_openai_metric_recorded_for_embeddings_every_time
    in_transaction do
      stub_embeddings_post_request do
        client.embeddings(parameters: embeddings_params)
        client.embeddings(parameters: embeddings_params)
      end
    end

    assert_metrics_recorded({"Supportability/Ruby/ML/OpenAI/#{::OpenAI::VERSION}" => {call_count: 2}})
  end

  def test_embedding_event_sets_error_true_if_raised
    txn = raise_segment_error do
      client.embeddings(parameters: embeddings_params)
    end
    segment = embedding_segment(txn)

    refute_nil segment.llm_event
    assert_truthy segment.llm_event.error
  end

  def test_set_llm_agent_attribute_on_embedding_transaction
    in_transaction do
      stub_embeddings_post_request do
        client.embeddings(parameters: embeddings_params)
      end
    end

    assert_truthy harvest_transaction_events![1][0][2][:llm]
  end

  def test_token_count_recorded_from_usage_object_when_present_on_embeddings
    in_transaction do
      stub_embeddings_post_request do
        client.embeddings(parameters: embeddings_params)
      end
    end

    _, events = @aggregator.harvest!
    embedding_event = events.find { |event| event[0]['type'] == NewRelic::Agent::Llm::Embedding::EVENT_NAME }

    assert_equal EmbeddingsResponse.new.body['usage']['prompt_tokens'], embedding_event[1]['token_count']
  end

  def test_token_count_nil_when_usage_is_missing_on_embeddings_and_no_callback_defined
    mock_response = {'model' => 'gpt-2001'}
    mock_event = NewRelic::Agent::Llm::Embedding.new(request_model: 'gpt-2004', input: 'what does my dog want?')
    add_embeddings_response_params(mock_response, mock_event)

    assert_nil mock_event.token_count
  end

  def test_token_count_assigned_by_callback_when_usage_is_missing_and_callback_defined
    NewRelic::Agent.set_llm_token_count_callback(proc { |hash| 7734 })

    mock_response = {'model' => 'gpt-2001'}
    mock_event = NewRelic::Agent::Llm::Embedding.new(request_model: 'gpt-2004', input: 'what does my dog want?')
    add_embeddings_response_params(mock_response, mock_event)

    assert_equal 7734, mock_event.token_count

    NewRelic::Agent.remove_instance_variable(:@llm_token_count_callback)
  end

  def test_token_count_when_message_not_response_and_usage_present_and_only_one_request_message
    message = NewRelic::Agent::Llm::ChatCompletionMessage.new(content: 'pineapple strawberry')
    response = {'usage' => {'prompt_tokens' => 123456, 'completion_tokens' => 654321}, 'model' => 'gpt-2001'}
    parameters = {'messages' => ['one']}

    result = calculate_message_token_count(message, response, parameters)

    assert_equal 123456, result
  end

  def test_token_count_when_message_not_response_and_usage_present_and_only_one_request_message_and_messages_params_symbol
    message = NewRelic::Agent::Llm::ChatCompletionMessage.new(content: 'pineapple strawberry')
    response = {'usage' => {'prompt_tokens' => 123456, 'completion_tokens' => 654321}, 'model' => 'gpt-2001'}
    parameters = {:messages => ['one']}

    calculate_message_token_count(message, response, parameters)

    assert_equal 123456, message.token_count
  end

  def test_token_count_when_message_not_response_and_usage_present_and_multiple_request_messages_but_no_callback
    in_transaction do
      stub_post_request do
        result = client.chat(parameters: chat_params)
      end
    end

    _, events = @aggregator.harvest!
    chat_completion_messages = events.find { |event| event[0]['type'] == NewRelic::Agent::Llm::ChatCompletionMessage::EVENT_NAME }

    not_response_messages = chat_completion_messages.find { |event| !event[1].key?('is_response') }

    not_response_messages.each do |msg|
      assert_nil msg.token_count
    end
  end

  def test_token_count_when_message_is_response_and_usage_present
  end

  def test_token_count_from_callback_when_token_count_nil
  end
end
