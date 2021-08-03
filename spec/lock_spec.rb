# frozen_string_literal: true

require 'logger'
require 'stringio'
require_relative 'spec_helper'
require_relative '../lib/distributed-lock-google-cloud-storage/lock'

RSpec.describe DistributedLock::GoogleCloudStorage::Lock do
  DEFAULT_TIMEOUT = 15
  LOCK_PATH = 'ruby-lock'

  around(:each) do |ex|
    ex.run_with_retry retry: 3
  end

  def create(**options)
    DistributedLock::GoogleCloudStorage::Lock.new(
      bucket_name: require_envvar('TEST_GCLOUD_BUCKET'),
      path: LOCK_PATH,
      logger: Logger.new(log_output),
      cloud_storage_options: {
        credentials: require_envvar('TEST_GCLOUD_CREDENTIALS_PATH'),
      },
      **options)
  end

  def gcloud_bucket(**options)
    @bucket ||= begin
      storage = Google::Cloud::Storage.new(credentials: require_envvar('TEST_GCLOUD_CREDENTIALS_PATH'))
      storage.bucket(require_envvar('TEST_GCLOUD_BUCKET'), skip_lookup: true)
    end
  end

  def force_recreate_lock_object(**options)
    gcloud_bucket.create_file(StringIO.new, LOCK_PATH, cache_control: 'no-store', **options)
  end

  def force_erase_lock_object
    gcloud_bucket.file(LOCK_PATH, skip_lookup: true).delete
  rescue Google::Cloud::NotFoundError
    # Do nothing
  end


  let(:log_output) { StringIO.new }


  describe 'initial state' do
    before(:all) { force_erase_lock_object }

    let(:lock) { create }

    it 'is not locked' do
      expect(lock).not_to be_locked_according_to_internal_state
      expect(lock).not_to be_locked_according_to_server
    end

    it 'is not owned' do
      expect(lock).not_to be_owned_according_to_internal_state
      expect(lock).not_to be_owned_according_to_server
    end

    specify 'checking for health is not possible due to being unlocked' do
      expect { lock.healthy? }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
      expect { lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    specify 'unlocking is not possible due to being unlocked' do
      expect { lock.unlock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end
  end


  describe '#lock' do
    after :each do
      @thread.kill if @thread
      [@lock, @lock2].each do |lock|
        lock.abandon if lock
      end
    end

    it 'works' do
      force_erase_lock_object
      @lock = create

      @lock.lock(timeout: 0)
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end

    it 'waits until the lock object is no longer taken' do
      force_erase_lock_object
      @lock = create
      @lock.lock(timeout: 0)

      @lock2 = create(backoff_min: 0.05, backoff_max: 0.05)
      @thread = Thread.new do
        @lock2.lock(timeout: DEFAULT_TIMEOUT)
        Thread.current[:result] = {
          locked_according_to_internal_state: @lock2.locked_according_to_internal_state?,
          locked_according_to_server: @lock2.locked_according_to_server?,
          owned_according_to_internal_state: @lock2.owned_according_to_internal_state?,
          owned_according_to_server: @lock2.owned_according_to_server?,
          healthy: @lock2.healthy?,
        }
      end

      consistently(duration: 1, interval: 0.05) do
        expect(@thread).to be_alive
      end

      @lock.unlock
      eventually(timeout: 1, interval: 0.05) do
        !@thread.alive?
      end

      @thread.join
      result = @thread[:result]
      @thread = nil

      expect(result[:locked_according_to_internal_state]).to be_truthy
      expect(result[:locked_according_to_server]).to be_truthy
      expect(result[:owned_according_to_internal_state]).to be_truthy
      expect(result[:owned_according_to_server]).to be_truthy
      expect(result[:healthy]).to be_truthy
    end

    it 'raises AlreadyLockedError if called twice by the same instance and thread' do
      force_erase_lock_object
      @lock = create

      @lock.lock(timeout: 0)
      expect { @lock.lock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::AlreadyLockedError)
    end

    specify 'another thread fails to take the lock' do
      force_erase_lock_object
      @lock = create

      @lock.lock(timeout: 0)

      thr = Thread.new do
        Thread.current.report_on_exception = false
        @lock.lock(timeout: 0)
      end
      expect { thr.join }.to raise_error(DistributedLock::GoogleCloudStorage::TimeoutError)

      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end

    it 'retries if the lock object was deleted right after failing to create it' do
      @lock = create
      force_recreate_lock_object
      called = 0

      expect(@lock).to \
        receive(:create_lock_object).
        at_least(:once).
        and_wrap_original do |orig_method, *args|
          called += 1
          result = orig_method.call(*args)
          force_erase_lock_object if called == 1
          result
        end

      @lock.lock(timeout: DEFAULT_TIMEOUT)
      expect(log_output.string.scan('Lock was deleted right after having created it').size).to eq(1)
      expect(called).to eq(2)
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end

    it 'succeeds if the lock was previously abandoned by the same instance and thread' do
      @lock = create(instance_identity: 'foo', thread_safe: false)
      force_recreate_lock_object(metadata: { identity: 'foo' })

      expect(@lock).to receive(:create_lock_object).exactly(2).times.and_call_original
      @lock.lock(timeout: DEFAULT_TIMEOUT)
      expect(log_output.string.scan('Lock was already owned').size).to eq(1)
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end

    it 'cleans up stale locks' do
      @lock = create
      force_recreate_lock_object(metadata: { expires_at: 0 })

      @lock.lock(timeout: DEFAULT_TIMEOUT)
      expect(log_output.string.scan('Lock is stale').size).to eq(1)
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end
  end


  describe '#unlock' do
    before(:each) do
      force_erase_lock_object
      @lock = create
    end

    after :each do
      @lock.abandon if @lock
    end

    def lock_and_unlock
      @lock.lock(timeout: 0)
      deleted = nil
      expect { deleted = @lock.unlock }.not_to raise_error
      deleted
    end

    it 'releases the lock' do
      expect(lock_and_unlock).to be_truthy
      expect(@lock).not_to be_locked_according_to_internal_state
      expect(@lock).not_to be_locked_according_to_server
      expect(@lock).not_to be_owned_according_to_internal_state
      expect(@lock).not_to be_owned_according_to_server
    end

    specify 'checking for health is not possible due to being unlocked' do
      lock_and_unlock
      expect { @lock.healthy? }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
      expect { @lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    specify 'unlocking again is not possible' do
      lock_and_unlock
      expect { @lock.unlock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    it 'works if the lock object is already deleted' do
      @lock.lock(timeout: 0)
      force_erase_lock_object
      deleted = nil
      expect { deleted = @lock.unlock }.not_to raise_error
      expect(deleted).to be_falsey
      expect(@lock).not_to be_locked_according_to_internal_state
      expect(@lock).not_to be_locked_according_to_server
      expect(@lock).not_to be_owned_according_to_internal_state
      expect(@lock).not_to be_owned_according_to_server
    end
  end


  describe 'refreshing' do
    before :each do
      force_erase_lock_object
      @lock = create(refresh_interval: 0.1)
      @lock.lock(timeout: 0)
    end

    after :each do
      @lock.abandon if @lock
    end

    it 'updates the update time' do
      orig_timestamp = gcloud_bucket.file(LOCK_PATH).updated_at
      eventually(timeout: 5) do
        current_timestamp = gcloud_bucket.file(LOCK_PATH, skip_lookup: true).updated_at
        orig_timestamp != current_timestamp
      end
    end

    it 'declares unhealthiness when the metageneration number is inconsistent' do
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error

      gcloud_bucket.file(LOCK_PATH, skip_lookup: true).update do |f|
        f.metadata['something'] = '123'
      end
      eventually(timeout: 5) do
        !@lock.healthy?
      end
      expect { @lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::LockUnhealthyError)
    end

    it 'declares unhealthiness when the lock object is deleted' do
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error

      force_erase_lock_object
      eventually(timeout: 5) do
        !@lock.healthy?
      end
      expect { @lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::LockUnhealthyError)
    end
  end
end
