require 'spec_helper'

describe Thrift::MutexableThreadPoolServer do
  subject { Thrift::MutexableThreadPoolServer.new double('processor'), double('server_transport') }

  before(:all) {
    class Thrift::Thread < ::Thread
      def self.new(*args, &block)
        self.block = block if block_given?
        @block
      end

      def self.block=(block)
        @block = block
      end

      def self.block
        @block
      end
    end
  }

  after(:all) {
    Thrift.send(:remove_const, :Thread)
  }

  let(:server)        { subject }
  let(:thread_block)  { Thrift::Thread.block }
  let(:queue_thread)  { proc { server.queue_thread }}

  before(:each) { Thrift::Thread.block = nil }

  describe "#serve" do
    before(:each) {
      server.server_transport.should_receive(:close)
      server.server_transport.should_receive(:listen)
      server.should_receive(:running!)
    }

    it "should execute a callback" do
      server.serve { server.stopped! }

      server.state.should be(:stopped)
    end

    it "should queue threads while the run loop is true" do
      server.should_receive(:run_loop?).once { true }
      server.should_receive(:run_loop?).once { false }

      server.serve do
        server.thread_q.clear
        server.should_receive(:queue_thread)

        server.stub(:queue_thread) { fail "Y U CALL" }
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
      server.stub(:unlocked?) { true }
      server.stub(:running?) { true }
      server.run_loop?.should be_true
    end

    it "should return false if locked" do
      server.stub(:unlocked?) { false }
      server.run_loop?.should be_false
    end

    it "should return false if not running" do
      server.stub(:unlocked?) { true }
      server.stub(:running?) { false }
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
  end

  describe "Inside the Thread Itself" do
    it "should only execute if run_loop? is true" do
      server.should_receive(:run_loop?).once { false }

      server.queue_thread

      thread_block.should be_a(Proc)
      thread_block.call
    end

    it "should remove an element from 'thread_q'" do
      server.should_receive(:run_loop?) { false }

      lambda {
        queue_thread.call
      }.should change(server.thread_q, :length).by( 1)

      lambda {
        thread_block.call
      }.should change(server.thread_q, :length).by(-1)
    end

    it "should remove itself from the 'threads'" do
      server.should_receive(:run_loop?) { false }

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

      server.should_receive(:run_loop?) { true }
      server.should_receive(:run_loop?) { false }

      server.should_receive(:wait_for_work).with(thread_block)   { :some_work }
      server.should_receive(:start_processing).with(:some_work)  { :processed }

      thread_block.call
    end

    # Alert! Not the most useful test:
    it "should not call wait_for_work or start_processing if run_loop is false" do
      queue_thread.call

      server.should_receive(:run_loop?) { false }
      server.stub(:wait_for_work).with(thread_block)  { fail 'I SHOULDNT BE CALLED' }
      server.stub(:start_processing)                  { fail 'I SHOULDNT BE CALLED' }

      thread_block.call
    end
  end

  describe "#wait_for_work" do
    it "should set the status before and after waiting for a client connection" do
      queue_thread.call

      server.should_receive(:run_loop?) { true  }
      server.should_receive(:run_loop?) { false }

      server.should_receive(:start_processing).with(:client)

      server.should_receive(:set_waiting_status).with(thread_block)

      server.stub(:set_working_status).with(thread_block) { fail "I should not be called, until after a client connection is received." }

      server.server_transport.should_receive(:accept) {
        server.should_receive(:set_working_status).with(thread_block) { "Hooray! Now I won't fail your test" }
        :client
      }

      thread_block.call
    end
  end
end
