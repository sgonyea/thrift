require 'spec_helper'

describe Thrift::MutexableThreadPoolServer do
  subject { Thrift::MutexableThreadPoolServer.new nil, nil }

  def Thread.block=(block); @block = block; end
  def Thread.block(&block)
    self.block = block if block_given?
    return(@block)
  end

  let(:server)        { subject }
  let(:thread_block)  { Thread.block }
  let(:queue_thread)  { proc { server.queue_thread }}

  before(:each) {
    Thread.block = nil
    stub(Thread).new.implemented_by(Thread.method(:block))
  }

  describe "#serve" do
    before(:each) {
      mock(server.server_transport).close
      mock(server.server_transport).listen
      mock(server).running!
    }

    it "should execute a callback" do
      server.serve { server.stopped! }

      server.state.should be(:stopped)
    end

    it "should queue threads while the run loop is true" do
      mock(server).run_loop?.once { true }
      mock(server).run_loop?.once { false }

      server.serve do
        server.thread_q.clear
        mock(server).queue_thread

        stub(server).queue_thread { fail "Y U CALL" }
      end
    end
  end

  describe "#status" do
    it "should assign default value to new key" do
      server.status['something'].should == :waiting
    end

    it "should retain assignments" do
      server.status['something'] = :not_waiting
      server.status['something'].should == :not_waiting
    end
  end

  describe "#run_loop?" do
    it "should return true if unlocked and running" do
      stub(server).unlocked? { true }
      stub(server).running? { true }
      server.run_loop?.should be_true
    end

    it "should return false if locked" do
      stub(server).unlocked? { false }
      server.run_loop?.should be_false
    end

    it "should return false if not running" do
      stub(server).unlocked? { true }
      stub(server).running? { false }
      server.run_loop?.should be_false
    end
  end

  describe "#mutex=, #unlocked?" do
    let(:mtx) { Mutex.new }

    it "should re-define the #unlocked? method if a Mutex is passed in" do
      server.mutex.should be_nil
      server.unlocked?.should be_true

      server.mutex = mtx
      server.unlocked?.should be_true

      mtx.lock
      server.unlocked?.should be_false
    end
  end

  describe "#queue_thread" do
    before(:each) {
      mock(Thread).new.implemented_by(Thread.method(:block))
    }

    context "Before and After Thread Creation" do
      it "should add token to thread queue" do
        lambda {
          queue_thread.call
        }.should change(server.thread_q, :length).by(1)
      end

      it "should add thread to thread set" do
        lambda {
          queue_thread.call
        }.should change(server.threads, :length).by(1)
      end
    end

    context "Inside the Thread Itself" do
      it "should only execute if run_loop? is true" do
        mock(server).run_loop? { false }

        server.queue_thread

        thread_block.should be_a(Proc)
        thread_block.call
      end

      it "should remove an element from 'thread_q'" do
        mock(server).run_loop? { false }

        lambda {
          queue_thread.call
        }.should change(server.thread_q, :length).by( 1)
        
        lambda {
          thread_block.call
        }.should change(server.thread_q, :length).by(-1)
      end

      it "should remove itself from the 'threads'" do
        mock(server).run_loop? { false }

        lambda {
          queue_thread.call
        }.should change(server.threads, :length).by(1)

        server.threads.should include(thread_block)

        lambda {
          thread_block.call
        }.should change(server.threads, :length).by(-1)

        server.threads.should_not include(thread_block)
      end

      # Alert! Not the most useful test:
      it "should wait_for_work and call into start_processing only if run_loop is true" do
        queue_thread.call

        mock(server).run_loop? { true  }
        mock(server).run_loop? { false }

        mock(server).wait_for_work(thread_block)   { :some_work }
        mock(server).start_processing(:some_work)  { :processed }

        thread_block.call
      end

      # Alert! Not the most useful test:
      it "should not call wait_for_work or start_processing if run_loop is false" do
        queue_thread.call

        mock(server).run_loop? { false }
        stub(server).wait_for_work(thread_block)     { fail 'I SHOULDNT BE CALLED' }
        stub(server).start_processing.with_any_args  { fail 'I SHOULDNT BE CALLED' }

        thread_block.call
      end
    end
  end

  describe "#wait_for_work" do
    it "should set the status before and after waiting for a client connection" do
      queue_thread.call

      mock(server).run_loop? { true  }
      mock(server).run_loop? { false }

      mock(server).start_processing(:client)

      mock(server).set_waiting_status(thread_block)
      stub(server).set_working_status(thread_block) { fail "I should not be called, until after a client connection is received." }

      mock(server.server_transport).accept {
        mock(server).set_working_status(thread_block) { "Hooray! Now I won't fail your test" }
        :client
      }

      thread_block.call
    end
  end
end
